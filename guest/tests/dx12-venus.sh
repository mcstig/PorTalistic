#!/usr/bin/env bash
# dx12-venus: vkd3d-proton's own DirectX 12 tests on the Mac's GPU, the way games reach it:
# x86 code through FEX, the x86 Venus driver in FEX's graphics rootfs, the bottle's x86 layer
# (feature stand-ins), virtio-gpu, KosmicKrisp, Metal. Runs `bottle selftest dx12-venus`
# (or a file logs/.selftest holding "dx12-venus"); the result lands in the kit's logs/.
#
# The tests come from vkd3d-proton 3.0.1 built for Linux (dx12-venus/tests/d3d12 with its two
# libraries; the C++ runtime built in), the same code as the d3d12.dll games load. Each test
# runs alone with a time limit so one hang or crash doesn't stop the rest.
#
# Env: DX12_TESTS="test_a test_b" (default: the list below), DX12_TEST_SECS (default 120),
# DX12_DEVICE (part of the GPU name; default Venus).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/dx12-venus" || exit 1
R="${GUEST_ROOTFS:-/usr/share/guestos/fex-mesa}"
work="$(mktemp -d)"
th="$work/thunks.json"; echo '{"ThunksDB": {"Vulkan": 0, "GL": 0}}' > "$th"

echo "== $(date)"
echo "== the x86 layer games get (FEX rootfs) and the kit's build"
md5sum "$R/usr/lib64/libVkLayer_bottle_present.so" ~/.cache/steamos-bottle/kit/guest/present-layer/x86_64/libVkLayer_bottle_present.so 2>&1 | sed 's#  # #'
for so in libvulkan.so.1 libm.so.6 libc.so.6; do
  compgen -G "$R/usr/lib64/$so*" >/dev/null && echo "rootfs has $so" || echo "rootfs is MISSING $so"
done

tests="${DX12_TESTS:-test_create_device test_clear_render_target_view test_clear_depth_stencil_view
  test_draw_instanced test_draw_indexed_instanced test_draw_uav_only test_texture_resource_barriers
  test_map_resource test_map_placed_resources test_root_constants test_update_descriptor_tables
  test_shader_instructions_dxil test_shader_interstage_interface test_sample_instructions test_texture_ld
  test_constant_buffer_dxil test_typed_buffer_uav test_buffer_srv test_uav_load test_compute_shader_registers
  test_clear_unordered_access_view_buffer test_clear_unordered_access_view_image
  test_copy_buffer_texture test_query_timestamp test_query_occlusion test_resolve_batch test_execute_indirect
  test_bundle_state_inheritance test_multisample_rendering test_multisample_resolve test_shader_fp16
  test_tessellation_read_tesslevel test_render_pass_suspend_resume_opts_enabled test_fence_wait_multiple}"
# Not in the default list: test_large_texel_buffer_view took the whole VM down (Oct 10, 22:17:
# Metal stops the process on a texture buffer wider than 2^28; the layer now cuts such views),
# and tests of what the Mac's GPU lacks (geometry shaders, stream output, pipeline statistics,
# custom border colours): nothing to learn there, and each is another chance of the same.

total_fail=0; n=0
for t in $tests; do
  n=$((n + 1)); log="$work/$t.log"; start=$(date +%s)
  env DISPLAY=:1 FEX_ROOTFS="$R" FEX_THUNKCONFIG="$th" VKD3D_FILTER_DEVICE_NAME="${DX12_DEVICE:-Venus}" \
      VKD3D_DEBUG=warn VKD3D_SHADER_CACHE_PATH=0 VKD3D_FEATURE_LEVEL=12_0 VKD3D_TEST_MATCH="$t" \
      VN_DEBUG=no_abort timeout "${DX12_TEST_SECS:-120}" ./tests/d3d12 > "$log" 2>&1
  rc=$?; secs=$(( $(date +%s) - start ))
  sum="$(grep -o '[0-9]* tests executed ([0-9]* failures[^)]*)' "$log" | tail -1)"
  f="$(grep -o '([0-9]* failures' <<<"$sum" | grep -o '[0-9]*')"
  total_fail=$((total_fail + ${f:-0}))
  case $rc in 0) st=ok;; 124) st=TIMEOUT;; *) st="exit $rc";; esac
  echo "== $t: $st in ${secs}s, ${sum:-no summary}"
  # what went wrong, briefly: failed checks, vkd3d's and the layer's complaints, a crash
  grep -a -E "Test failed|Test skipped|err:|Lacking|not supported|bottle-present\] (DirectX|reporting|vkCreateDevice)|Segmentation|Aborted|core dumped|MESA-VIRTIO|DEVICE_LOST|device lost" "$log" \
    | grep -a -v "Optional " | sed 's/^[0-9a-f]\{4\}://' | sort | uniq -c | sort -rn | head -12 | cut -c1-240
  if [[ -z "$sum" ]]; then echo "-- last lines:"; tail -n 8 "$log" | cut -c1-240; fi
done
echo "== $n tests, $total_fail failed checks in all"
rm -rf "$work"
