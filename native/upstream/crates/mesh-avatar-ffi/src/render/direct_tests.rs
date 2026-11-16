use super::*;
use crate::{mesh_avatar_destroy, mesh_avatar_open_bytes, mesh_avatar_tick};

#[test]
fn shared_metal_output_matches_legacy_pixels_and_completes_before_release() {
    // 仅测试读取 GPU 像素作对照；播放器本身不执行回读。
    let bytes = include_bytes!("../../../../../../example/assets/miko/miko-qipao.mavatar");
    let mut avatar = 0;
    assert_eq!(
        unsafe { mesh_avatar_open_bytes(bytes.as_ptr(), bytes.len(), &mut avatar) },
        MA_OK
    );
    let options = MaRenderOptions {
        width: 120,
        height: 160,
        samples: 1,
        fit: MA_FIT_COVER,
        pad_top: 0.06,
        pad_side: 0.02,
    };
    let mut gpu = 0;
    assert_eq!(
        unsafe { mesh_avatar_gpu_create(avatar, &options, std::ptr::null_mut(), &mut gpu) },
        MA_OK
    );
    let mut legacy = 0;
    assert_eq!(
        unsafe { mesh_avatar_renderer_create(avatar, &options, &mut legacy) },
        MA_OK
    );
    let mut pointer = std::ptr::null_mut();
    assert_eq!(
        unsafe { mesh_avatar_gpu_metal_device(gpu, &mut pointer) },
        MA_OK
    );
    let device = unsafe { metal::DeviceRef::from_ptr(pointer.cast()) };
    let descriptor = metal::TextureDescriptor::new();
    descriptor.set_texture_type(metal::MTLTextureType::D2);
    descriptor.set_pixel_format(metal::MTLPixelFormat::BGRA8Unorm);
    descriptor.set_width(120);
    descriptor.set_height(160);
    descriptor.set_storage_mode(metal::MTLStorageMode::Shared);
    descriptor.set_usage(metal::MTLTextureUsage::RenderTarget);
    let texture = device.new_texture(&descriptor);
    let mut serial = 0;
    assert_eq!(
        unsafe { mesh_avatar_gpu_draw_metal(gpu, std::ptr::null_mut(), &mut serial) },
        MA_INVALID_ARGUMENT
    );
    let mut previous = 0;
    for _ in 0..3 {
        assert_eq!(mesh_avatar_tick(avatar, 0.033), MA_OK);
        let mut rgba = vec![0; 120 * 160 * 4];
        assert_eq!(
            unsafe {
                mesh_avatar_renderer_render(
                    legacy,
                    rgba.as_mut_ptr(),
                    rgba.len(),
                    MA_RGBA_PREMULTIPLIED,
                )
            },
            MA_OK
        );
        assert_eq!(
            unsafe { mesh_avatar_gpu_draw_metal(gpu, texture.as_ptr().cast(), &mut serial) },
            MA_OK
        );
        assert!(serial > previous);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut completed = 0;
        while completed < serial {
            assert_eq!(unsafe { mesh_avatar_gpu_poll(gpu, &mut completed) }, MA_OK);
            assert!(
                std::time::Instant::now() < deadline,
                "GPU 未完成共享纹理写入"
            );
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        let mut bgra = vec![0u8; rgba.len()];
        texture.get_bytes(
            bgra.as_mut_ptr().cast(),
            120 * 4,
            metal::MTLRegion::new_2d(0, 0, 120, 160),
            0,
        );
        assert!(
            rgba.chunks_exact(4).any(|p| p[3] == 0),
            "模型必须保留透明背景"
        );
        assert!(rgba.chunks_exact(4).any(|p| p[3] > 200), "模型必须实际出图");
        for (old, new) in rgba.chunks_exact(4).zip(bgra.chunks_exact(4)) {
            for channel in 0..4 {
                let mapped = [2, 1, 0, 3][channel];
                assert!(
                    old[channel].abs_diff(new[mapped]) <= 1,
                    "共享输出的颜色、方向或透明度发生变化"
                );
            }
        }
        previous = serial;
    }
    assert_eq!(mesh_avatar_gpu_destroy(gpu), MA_OK);
    assert_eq!(
        unsafe { mesh_avatar_gpu_poll(gpu, &mut serial) },
        MA_INVALID_HANDLE
    );
    assert_eq!(mesh_avatar_renderer_destroy(legacy), MA_OK);
    assert_eq!(mesh_avatar_destroy(avatar), MA_OK);
}
