# AMD AMF headers (vendored)

`include/` is a verbatim copy of `amf/public/include` from the GPUOpen AMF repository
(https://github.com/GPUOpen-LibrariesAndSDKs/AMF), taken from `master` on 2026-10-08
(headers report API version 1.5.2).

Only the AVC (H.264) encoder headers are used, by
`pc/flow_steamvr_driver/src/flow_amf_encoder.cpp`, which loads the runtime DLL
`amfrt64.dll` dynamically. That DLL ships with the AMD Radeon driver, so no AMF SDK or
extra download is needed to build or run this project.

Licensed under the MIT license, see `LICENSE.txt`. Note the notice at the top of that file:
AMD grants no patent license for the media technologies (H.264 among them), so whoever
distributes an encoder is responsible for the royalties. The NVIDIA NVENC path has the same
consideration.
