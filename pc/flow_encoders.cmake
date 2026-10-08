# Libraries the shared video-encoder backends need.
#
# The driver and the dashboard helper both compile flow_video_encoder.cpp,
# flow_nvenc_encoder.cpp and flow_amf_encoder.cpp, so the Windows libraries they require live here
# instead of in two places that can drift apart:
#
#   d3d11, dxgi  - the D3D11 device, textures and NV12 plane render targets
#   d3dcompiler  - D3DCompile for the AMF backend's BGRA -> NV12 shader (easy to forget: the
#                  helper failed to link with "LNK2019: unresolved external symbol D3DCompile"
#                  before this list existed)
#   ole32        - CoTaskMemFree, reached through the AMF headers
#
# NVENC itself needs no import library: nvEncodeAPI64.dll is loaded by hand at run time. Neither
# does AMF: amfrt64.dll comes with the Radeon driver and is loaded by hand too.
set(FLOW_ENCODER_LIBS d3d11 dxgi d3dcompiler ole32)
