import runpod
from runpod.serverless.utils import rp_upload
import json
import urllib.parse
import time
import os
import requests
import base64
from io import BytesIO
import websocket
import uuid
import tempfile
import socket
import traceback
import logging

from network_volume import (
    is_network_volume_debug_enabled,
    run_network_volume_diagnostics,
)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Tunables (env-overridable)
# ---------------------------------------------------------------------------
COMFY_API_AVAILABLE_INTERVAL_MS  = int(os.environ.get("COMFY_API_AVAILABLE_INTERVAL_MS", 1000))
COMFY_API_AVAILABLE_MAX_RETRIES  = int(os.environ.get("COMFY_API_AVAILABLE_MAX_RETRIES", 0))
COMFY_API_FALLBACK_MAX_RETRIES   = 500
COMFY_PID_FILE                   = "/tmp/comfyui.pid"
WEBSOCKET_RECONNECT_ATTEMPTS     = int(os.environ.get("WEBSOCKET_RECONNECT_ATTEMPTS", 5))
WEBSOCKET_RECONNECT_DELAY_S      = int(os.environ.get("WEBSOCKET_RECONNECT_DELAY_S", 3))

if os.environ.get("WEBSOCKET_TRACE", "false").lower() == "true":
    websocket.enableTrace(True)

# ---------------------------------------------------------------------------
# ComfyUI connection — reads COMFY_HOST / COMFY_PORT from env
# so Dockerfile ENV values are always respected; UI overrides also work.
# ---------------------------------------------------------------------------
COMFY_HOST_ONLY = os.environ.get("COMFY_HOST", "127.0.0.1")
COMFY_PORT      = int(os.environ.get("COMFY_PORT", "8188"))
COMFY_HTTP_BASE = f"http://{COMFY_HOST_ONLY}:{COMFY_PORT}"
COMFY_WS_BASE   = f"ws://{COMFY_HOST_ONLY}:{COMFY_PORT}"
# Human-readable label for log messages
COMFY_HOST      = f"{COMFY_HOST_ONLY}:{COMFY_PORT}"

REFRESH_WORKER = os.environ.get("REFRESH_WORKER", "false").lower() == "true"

print(f"[handler] ComfyUI HTTP base : {COMFY_HTTP_BASE}")
print(f"[handler] ComfyUI WS base   : {COMFY_WS_BASE}")
print(f"[handler] REFRESH_WORKER    : {REFRESH_WORKER}")


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _comfy_server_status():
    """Quick reachability probe — returns dict with 'reachable' key."""
    try:
        resp = requests.get(f"{COMFY_HTTP_BASE}/", timeout=5)
        return {"reachable": resp.status_code == 200, "status_code": resp.status_code}
    except Exception as exc:
        return {"reachable": False, "error": str(exc)}


def _get_comfyui_pid():
    try:
        with open(COMFY_PID_FILE, "r") as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return None


def _is_comfyui_process_alive():
    """True = alive, False = dead, None = PID file not found."""
    pid = _get_comfyui_pid()
    if pid is None:
        return None
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _attempt_websocket_reconnect(ws_url, max_attempts, delay_s, initial_error):
    """
    Retry websocket connection up to max_attempts times.
    Returns a new connected WebSocket or raises WebSocketConnectionClosedException.
    """
    print(
        f"worker-comfyui - Websocket closed unexpectedly: {initial_error}. "
        "Attempting to reconnect..."
    )
    last_err = initial_error
    for attempt in range(max_attempts):
        srv = _comfy_server_status()
        if not srv["reachable"]:
            print(
                f"worker-comfyui - ComfyUI HTTP unreachable during reconnect: "
                f"{srv.get('error', 'status ' + str(srv.get('status_code')))}"
            )
            raise websocket.WebSocketConnectionClosedException(
                "ComfyUI HTTP unreachable during websocket reconnect"
            )
        print(
            f"worker-comfyui - Reconnect attempt {attempt + 1}/{max_attempts} "
            f"(ComfyUI HTTP status {srv.get('status_code')})..."
        )
        try:
            new_ws = websocket.WebSocket()
            new_ws.connect(ws_url, timeout=10)
            print("worker-comfyui - Websocket reconnected successfully.")
            return new_ws
        except (websocket.WebSocketException, ConnectionRefusedError, socket.timeout, OSError) as e:
            last_err = e
            print(f"worker-comfyui - Reconnect attempt {attempt + 1} failed: {e}")
            if attempt < max_attempts - 1:
                print(f"worker-comfyui - Waiting {delay_s}s before next attempt...")
                time.sleep(delay_s)
    print("worker-comfyui - Max reconnection attempts reached.")
    raise websocket.WebSocketConnectionClosedException(
        f"Failed to reconnect after {max_attempts} attempts. Last error: {last_err}"
    )


# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

def validate_input(job_input):
    if job_input is None:
        return None, "Please provide input"
    if isinstance(job_input, str):
        try:
            job_input = json.loads(job_input)
        except json.JSONDecodeError:
            return None, "Invalid JSON format in input"
    workflow = job_input.get("workflow")
    if workflow is None:
        return None, "Missing 'workflow' parameter"
    images = job_input.get("images")
    if images is not None:
        if not isinstance(images, list) or not all(
            "name" in img and "image" in img for img in images
        ):
            return None, "'images' must be a list of objects with 'name' and 'image' keys"
    return {
        "workflow": workflow,
        "images": images,
        "comfy_org_api_key": job_input.get("comfy_org_api_key"),
    }, None


# ---------------------------------------------------------------------------
# Server readiness check
# ---------------------------------------------------------------------------

def check_server(url, retries=0, delay=1000):
    """
    Poll ComfyUI HTTP server until ready.
    retries=0 means unlimited (but respects PID liveness).
    """
    WARN_THRESHOLD = 30
    delay = max(1, delay)
    log_every = max(1, int(10_000 / delay))
    attempt = 0

    print(f"[handler] Probing ComfyUI at {url} ...")

    while True:
        process_status = _is_comfyui_process_alive()
        if process_status is False:
            print(
                "[handler] ❌ ComfyUI process has exited — "
                "check container logs for Python traceback / OOM-kill."
            )
            return False
        try:
            response = requests.get(url, timeout=5)
            if response.status_code == 200:
                elapsed_s = (attempt * delay) / 1000
                msg = (
                    f"after {attempt} probe(s) ({elapsed_s:.0f}s)."
                    if attempt > 0 else "immediately."
                )
                print(f"[handler] ✅ ComfyUI API reachable {msg}")
                return True
        except requests.Timeout:
            reason = "connection timed out"
        except requests.ConnectionError:
            reason = "connection refused"
        except requests.RequestException as exc:
            reason = str(exc)

        attempt += 1
        elapsed_s = (attempt * delay) / 1000
        fallback = retries if retries > 0 else COMFY_API_FALLBACK_MAX_RETRIES
        if process_status is None and attempt >= fallback:
            print(
                f"[handler] ❌ ComfyUI unreachable after {fallback} attempts "
                f"({elapsed_s:.0f}s) — no PID file, giving up."
            )
            return False
        level = "WARNING" if attempt >= WARN_THRESHOLD else ("INFO" if attempt > 1 else "DEBUG")
        if attempt == 1 or attempt % log_every == 0:
            print(
                f"[handler] [{level}] ComfyUI not responding ({reason}) — "
                f"attempt {attempt}, {elapsed_s:.0f}s elapsed. "
                + ("Check ComfyUI logs." if attempt >= WARN_THRESHOLD else "Retrying ...")
            )
        time.sleep(delay / 1000)


# ---------------------------------------------------------------------------
# ComfyUI API calls
# ---------------------------------------------------------------------------

def upload_images(images):
    """Upload base64-encoded images to ComfyUI /upload/image."""
    if not images:
        return {"status": "success", "message": "No images to upload", "details": []}

    responses, upload_errors = [], []
    print(f"worker-comfyui - Uploading {len(images)} image(s)...")

    for image in images:
        try:
            name = image["name"]
            raw = image["image"]
            base64_data = raw.split(",", 1)[1] if "," in raw else raw
            blob = base64.b64decode(base64_data)
            files = {"image": (name, BytesIO(blob), "image/png"), "overwrite": (None, "true")}
            resp = requests.post(f"{COMFY_HTTP_BASE}/upload/image", files=files, timeout=30)
            resp.raise_for_status()
            responses.append(f"Successfully uploaded {name}")
            print(f"worker-comfyui - Uploaded {name}")
        except base64.binascii.Error as e:
            msg = f"Base64 decode error for {image.get('name', 'unknown')}: {e}"
            print(f"worker-comfyui - {msg}"); upload_errors.append(msg)
        except requests.Timeout:
            msg = f"Timeout uploading {image.get('name', 'unknown')}"
            print(f"worker-comfyui - {msg}"); upload_errors.append(msg)
        except requests.RequestException as e:
            msg = f"Request error uploading {image.get('name', 'unknown')}: {e}"
            print(f"worker-comfyui - {msg}"); upload_errors.append(msg)
        except Exception as e:
            msg = f"Unexpected error uploading {image.get('name', 'unknown')}: {e}"
            print(f"worker-comfyui - {msg}"); upload_errors.append(msg)

    if upload_errors:
        print("worker-comfyui - Upload finished with errors.")
        return {"status": "error", "message": "Some images failed to upload", "details": upload_errors}
    print("worker-comfyui - All images uploaded.")
    return {"status": "success", "message": "All images uploaded successfully", "details": responses}


def get_available_models():
    """Fetch checkpoint list from ComfyUI /object_info."""
    try:
        resp = requests.get(f"{COMFY_HTTP_BASE}/object_info", timeout=10)
        resp.raise_for_status()
        info = resp.json()
        models = {}
        if "CheckpointLoaderSimple" in info:
            ckpt = info["CheckpointLoaderSimple"].get("input", {}).get("required", {}).get("ckpt_name")
            if ckpt and len(ckpt) > 0:
                models["checkpoints"] = ckpt[0] if isinstance(ckpt[0], list) else []
        return models
    except Exception as e:
        print(f"worker-comfyui - Warning: could not fetch available models: {e}")
        return {}


def queue_workflow(workflow, client_id, comfy_org_api_key=None):
    """
    POST workflow to ComfyUI /prompt.
    Raises ValueError on validation errors with detailed messages.
    """
    payload = {"prompt": workflow, "client_id": client_id}
    effective_key = comfy_org_api_key or os.environ.get("COMFY_ORG_API_KEY")
    if effective_key:
        payload["extra_data"] = {"api_key_comfy_org": effective_key}

    data = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    resp = requests.post(f"{COMFY_HTTP_BASE}/prompt", data=data, headers=headers, timeout=30)

    if resp.status_code == 400:
        print(f"worker-comfyui - ComfyUI 400. Body: {resp.text}")
        try:
            err = resp.json()
            error_message = "Workflow validation failed"
            error_details = []

            if "error" in err:
                ei = err["error"]
                error_message = ei.get("message", error_message) if isinstance(ei, dict) else str(ei)

            if "node_errors" in err:
                for nid, ne in err["node_errors"].items():
                    if isinstance(ne, dict):
                        for et, em in ne.items():
                            error_details.append(f"Node {nid} ({et}): {em}")
                    else:
                        error_details.append(f"Node {nid}: {ne}")

            if err.get("type") == "prompt_outputs_failed_validation":
                error_message = err.get("message", error_message)
                avail = get_available_models()
                suffix = (
                    f"\nAvailable checkpoints: {', '.join(avail['checkpoints'])}"
                    if avail.get("checkpoints")
                    else "\nNo checkpoint models found — check model installation."
                )
                raise ValueError(error_message + "\n\nUsually a missing model/parameter." + suffix)

            if error_details:
                detail_str = error_message + ":\n" + "\n".join(f"• {d}" for d in error_details)
                if any("not in list" in d and "ckpt_name" in d for d in error_details):
                    avail = get_available_models()
                    suffix = (
                        f"\nAvailable checkpoints: {', '.join(avail['checkpoints'])}"
                        if avail.get("checkpoints")
                        else "\nNo checkpoint models found — check model installation."
                    )
                    detail_str += suffix
                raise ValueError(detail_str)

            raise ValueError(f"{error_message}. Raw: {resp.text}")

        except (json.JSONDecodeError, KeyError) as e:
            raise ValueError(f"ComfyUI 400 (unparseable): {resp.text}")

    resp.raise_for_status()
    return resp.json()


def get_history(prompt_id):
    resp = requests.get(f"{COMFY_HTTP_BASE}/history/{prompt_id}", timeout=30)
    resp.raise_for_status()
    return resp.json()


def get_image_data(filename, subfolder, image_type):
    print(f"worker-comfyui - Fetching image: type={image_type}, subfolder={subfolder}, file={filename}")
    params = urllib.parse.urlencode({"filename": filename, "subfolder": subfolder, "type": image_type})
    try:
        resp = requests.get(f"{COMFY_HTTP_BASE}/view?{params}", timeout=60)
        resp.raise_for_status()
        print(f"worker-comfyui - Fetched {filename}")
        return resp.content
    except requests.Timeout:
        print(f"worker-comfyui - Timeout fetching {filename}")
    except requests.RequestException as e:
        print(f"worker-comfyui - Error fetching {filename}: {e}")
    except Exception as e:
        print(f"worker-comfyui - Unexpected error fetching {filename}: {e}")
    return None


# ---------------------------------------------------------------------------
# Main handler
# ---------------------------------------------------------------------------

def handler(job):
    """
    RunPod serverless handler.
    Receives a ComfyUI workflow (+ optional base64 images), executes it,
    and returns output images as base64 or S3 URLs.
    """
    if is_network_volume_debug_enabled():
        run_network_volume_diagnostics()

    job_input = job["input"]
    job_id    = job["id"]

    validated_data, error_message = validate_input(job_input)
    if error_message:
        return {"error": error_message}

    workflow     = validated_data["workflow"]
    input_images = validated_data.get("images")

    # Verify ComfyUI is reachable before we do any work
    if not check_server(
        f"{COMFY_HTTP_BASE}/",
        COMFY_API_AVAILABLE_MAX_RETRIES,
        COMFY_API_AVAILABLE_INTERVAL_MS,
    ):
        return {"error": f"ComfyUI server ({COMFY_HTTP_BASE}) not reachable after multiple retries."}

    # Upload input images
    if input_images:
        upload_result = upload_images(input_images)
        if upload_result["status"] == "error":
            return {"error": "Failed to upload input images", "details": upload_result["details"]}

    ws         = None
    client_id  = str(uuid.uuid4())
    prompt_id  = None
    output_data = []
    errors      = []

    # WebSocket URL — clientId is the correct query param for ComfyUI WS
    ws_url = f"{COMFY_WS_BASE}/ws?clientId={client_id}"

    try:
        print(f"worker-comfyui - Connecting to websocket: {ws_url}")
        ws = websocket.WebSocket()
        ws.connect(ws_url, timeout=10)
        print("worker-comfyui - Websocket connected.")

        # Queue workflow — prompt payload uses client_id (snake_case, ComfyUI standard)
        try:
            queued = queue_workflow(
                workflow, client_id,
                comfy_org_api_key=validated_data.get("comfy_org_api_key"),
            )
            prompt_id = queued.get("prompt_id")
            if not prompt_id:
                raise ValueError(f"Missing 'prompt_id' in queue response: {queued}")
            print(f"worker-comfyui - Queued workflow, prompt_id={prompt_id}")
        except requests.RequestException as e:
            raise ValueError(f"Error queuing workflow: {e}")
        except Exception as e:
            raise e if isinstance(e, ValueError) else ValueError(f"Unexpected queue error: {e}")

        # Listen on websocket until execution completes
        print(f"worker-comfyui - Waiting for execution of {prompt_id} ...")
        execution_done = False

        while True:
            try:
                out = ws.recv()
                if not isinstance(out, str):
                    continue
                message = json.loads(out)
                mtype   = message.get("type")
                mdata   = message.get("data", {})

                if mtype == "status":
                    remaining = mdata.get("status", {}).get("exec_info", {}).get("queue_remaining", "N/A")
                    print(f"worker-comfyui - Queue remaining: {remaining}")

                elif mtype == "executing":
                    if mdata.get("node") is None and mdata.get("prompt_id") == prompt_id:
                        print(f"worker-comfyui - Execution finished for {prompt_id}")
                        execution_done = True
                        break

                elif mtype == "execution_error":
                    if mdata.get("prompt_id") == prompt_id:
                        detail = (
                            f"Node type: {mdata.get('node_type')}, "
                            f"Node id: {mdata.get('node_id')}, "
                            f"Message: {mdata.get('exception_message')}"
                        )
                        print(f"worker-comfyui - Execution error: {detail}")
                        errors.append(f"Workflow execution error: {detail}")
                        break

            except websocket.WebSocketTimeoutException:
                print("worker-comfyui - WS receive timed out, still waiting...")
                continue
            except websocket.WebSocketConnectionClosedException as closed_err:
                try:
                    ws = _attempt_websocket_reconnect(
                        ws_url, WEBSOCKET_RECONNECT_ATTEMPTS,
                        WEBSOCKET_RECONNECT_DELAY_S, closed_err,
                    )
                    print("worker-comfyui - Resuming after reconnect.")
                    continue
                except websocket.WebSocketConnectionClosedException as final_err:
                    raise final_err
            except json.JSONDecodeError:
                print("worker-comfyui - Invalid JSON on websocket, ignoring.")

        if not execution_done and not errors:
            raise ValueError("Execution loop exited without completion confirmation.")

        # Fetch history
        print(f"worker-comfyui - Fetching history for {prompt_id} ...")
        history = get_history(prompt_id)

        if prompt_id not in history:
            msg = f"Prompt ID {prompt_id} not found in history."
            print(f"worker-comfyui - {msg}")
            if not errors:
                return {"error": msg}
            errors.append(msg)
            return {"error": "Job failed, prompt not in history.", "details": errors}

        outputs = history.get(prompt_id, {}).get("outputs", {})
        if not outputs:
            warn = f"No outputs in history for {prompt_id}."
            print(f"worker-comfyui - {warn}")
            errors.append(warn)

        print(f"worker-comfyui - Processing {len(outputs)} output node(s)...")
        for node_id, node_output in outputs.items():
            if "images" in node_output:
                print(f"worker-comfyui - Node {node_id}: {len(node_output['images'])} image(s)")
                for img_info in node_output["images"]:
                    filename  = img_info.get("filename")
                    subfolder = img_info.get("subfolder", "")
                    img_type  = img_info.get("type")

                    if img_type == "temp":
                        print(f"worker-comfyui - Skipping temp image {filename}")
                        continue
                    if not filename:
                        w = f"Skipping node {node_id} image — missing filename: {img_info}"
                        print(f"worker-comfyui - {w}"); errors.append(w)
                        continue

                    image_bytes = get_image_data(filename, subfolder, img_type)
                    if not image_bytes:
                        errors.append(f"Failed to fetch {filename} from /view endpoint.")
                        continue

                    file_ext = os.path.splitext(filename)[1] or ".png"

                    if os.environ.get("BUCKET_ENDPOINT_URL"):
                        try:
                            with tempfile.NamedTemporaryFile(suffix=file_ext, delete=False) as tmp:
                                tmp.write(image_bytes)
                                tmp_path = tmp.name
                            s3_url = rp_upload.upload_image(job_id, tmp_path)
                            os.remove(tmp_path)
                            print(f"worker-comfyui - Uploaded {filename} → {s3_url}")
                            output_data.append({"filename": filename, "type": "s3_url", "data": s3_url})
                        except Exception as e:
                            msg = f"S3 upload error for {filename}: {e}"
                            print(f"worker-comfyui - {msg}"); errors.append(msg)
                            if "tmp_path" in locals() and os.path.exists(tmp_path):
                                try: os.remove(tmp_path)
                                except OSError: pass
                    else:
                        try:
                            b64 = base64.b64encode(image_bytes).decode("utf-8")
                            output_data.append({"filename": filename, "type": "base64", "data": b64})
                            print(f"worker-comfyui - Encoded {filename} as base64")
                        except Exception as e:
                            msg = f"Base64 encode error for {filename}: {e}"
                            print(f"worker-comfyui - {msg}"); errors.append(msg)

            other_keys = [k for k in node_output if k != "images"]
            if other_keys:
                print(f"worker-comfyui - WARNING: Node {node_id} has unhandled keys: {other_keys}")

    except websocket.WebSocketException as e:
        print(f"worker-comfyui - WebSocket error: {e}\n{traceback.format_exc()}")
        return {"error": f"WebSocket error: {e}"}
    except requests.RequestException as e:
        print(f"worker-comfyui - HTTP error: {e}\n{traceback.format_exc()}")
        return {"error": f"HTTP error with ComfyUI: {e}"}
    except ValueError as e:
        print(f"worker-comfyui - ValueError: {e}\n{traceback.format_exc()}")
        return {"error": str(e)}
    except Exception as e:
        print(f"worker-comfyui - Unexpected error: {e}\n{traceback.format_exc()}")
        return {"error": f"Unexpected error: {e}"}
    finally:
        if ws and ws.connected:
            print("worker-comfyui - Closing websocket.")
            ws.close()

    # Build final result
    final_result = {}
    if output_data:
        final_result["images"] = output_data
    if errors:
        final_result["errors"] = errors
        print(f"worker-comfyui - Completed with warnings: {errors}")

    if not output_data and errors:
        print("worker-comfyui - Job failed — no output images.")
        return {"error": "Job processing failed", "details": errors}

    if not output_data and not errors:
        print("worker-comfyui - Job succeeded but produced no images.")
        final_result["status"] = "success_no_images"
        final_result["images"] = []

    print(f"worker-comfyui - Done. Returning {len(output_data)} image(s).")
    return final_result


if __name__ == "__main__":
    print("worker-comfyui - Starting handler...")
    runpod.serverless.start({"handler": handler})
