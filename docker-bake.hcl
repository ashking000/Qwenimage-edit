# docker-bake.hcl  ── Qwen Image 2512 (Network Volume Edition)
# Only one build target: qwen2512-base
# Models are NOT baked in — they live on the network volume.

variable "DOCKERHUB_REPO"   { default = "ashking000" }
variable "DOCKERHUB_IMG"    { default = "qwenimage-edit" }
variable "RELEASE_VERSION"  { default = "latest" }
variable "COMFYUI_VERSION"  { default = "latest" }

variable "BASE_IMAGE" {
  default = "nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04"
}
variable "CUDA_VERSION_FOR_COMFY" { default = "12.6" }
variable "ENABLE_PYTORCH_UPGRADE" { default = "false" }
variable "PYTORCH_INDEX_URL"      { default = "" }

group "default" {
  targets = ["base"]
}

# Primary build target — no models baked in, uses network volume
target "base" {
  context    = "."
  dockerfile = "Dockerfile"
  target     = "base"
  platforms  = ["linux/amd64"]
  args = {
    BASE_IMAGE             = "${BASE_IMAGE}"
    COMFYUI_VERSION        = "${COMFYUI_VERSION}"
    CUDA_VERSION_FOR_COMFY = "${CUDA_VERSION_FOR_COMFY}"
    ENABLE_PYTORCH_UPGRADE = "${ENABLE_PYTORCH_UPGRADE}"
    PYTORCH_INDEX_URL      = "${PYTORCH_INDEX_URL}"
    MODEL_TYPE             = "base"
  }
  tags = ["${DOCKERHUB_REPO}/${DOCKERHUB_IMG}:${RELEASE_VERSION}"]
}
