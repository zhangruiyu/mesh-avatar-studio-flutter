//! Flutter 原生输出：Android 使用交换链，Apple 导入同设备的共享 Metal 纹理。
//! 旧的同步回读接口仍保留，播放器只调用本模块，不把整帧像素送回 CPU。
use super::*;
#[cfg(target_vendor = "apple")]
use foreign_types::{ForeignType, ForeignTypeRef};
use std::ffi::c_void;
#[cfg(target_vendor = "apple")]
use std::sync::atomic::{AtomicU64, Ordering};

struct GpuEntry {
    renderer: Renderer,
    device: wgpu::Device,
    queue: wgpu::Queue,
    avatar: MaHandle,
    size: [u32; 2],
    view: ViewOptions,
    alive: bool,
    #[cfg(target_os = "android")]
    instance: wgpu::Instance,
    #[cfg(target_os = "android")]
    adapter: wgpu::Adapter,
    #[cfg(target_os = "android")]
    surface: Option<wgpu::Surface<'static>>,
    #[cfg(target_os = "android")]
    config: wgpu::SurfaceConfiguration,
    #[cfg(target_vendor = "apple")]
    serial: u64,
    #[cfg(target_vendor = "apple")]
    completed: Arc<AtomicU64>,
}
type Entries = BTreeMap<MaRenderer, Arc<Mutex<GpuEntry>>>;
static ENTRIES: OnceLock<Mutex<Entries>> = OnceLock::new();
fn entries() -> &'static Mutex<Entries> {
    ENTRIES.get_or_init(|| Mutex::new(BTreeMap::new()))
}
fn with_gpu<T>(id: MaRenderer, work: impl FnOnce(&mut GpuEntry) -> Result<T>) -> Result<T> {
    let shared = entries()
        .lock()
        .map_err(|_| render_error("GPU 注册表已损坏"))?
        .get(&id)
        .cloned()
        .ok_or_else(|| Error::new(MA_INVALID_HANDLE, "GPU 句柄无效"))?;
    let mut entry = shared
        .lock()
        .map_err(|_| render_error("GPU 状态已损坏，请重新加载"))?;
    if !entry.alive {
        return Err(Error::new(MA_INVALID_HANDLE, "GPU 已销毁"));
    }
    work(&mut entry)
}

#[cfg(target_os = "android")]
unsafe fn android_surface(
    instance: &wgpu::Instance,
    window: *mut c_void,
) -> Result<wgpu::Surface<'static>> {
    use wgpu::rwh::*;
    let window = std::ptr::NonNull::new(window)
        .ok_or_else(|| Error::new(MA_INVALID_ARGUMENT, "Android 窗口为空"))?;
    // 调用方持有 ANativeWindow 引用，必须先解除 Surface 再释放该引用。
    unsafe {
        instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
            raw_display_handle: RawDisplayHandle::Android(AndroidDisplayHandle::new()),
            raw_window_handle: RawWindowHandle::AndroidNdk(AndroidNdkWindowHandle::new(window)),
        })
    }
    .map_err(render_error)
}

/// 创建直接输出渲染器。Android 窗口必须有效，Apple 传空指针。
/// 调用方提供有效且不重叠的 options/out；渲染器先于模型销毁。
#[no_mangle]
pub unsafe extern "C" fn mesh_avatar_gpu_create(
    avatar: MaHandle,
    options: *const MaRenderOptions,
    window: *mut c_void,
    out: *mut MaRenderer,
) -> MaStatus {
    boundary(|| {
        check_out(out)?;
        unsafe {
            out.write(0);
        }
        check_out(options.cast_mut())?;
        let options = unsafe { options.read() };
        let size = [options.width, options.height];
        rgba_length(size)?;
        if !matches!(options.samples, 1 | 4) {
            return Err(Error::new(MA_INVALID_ARGUMENT, "采样数必须为 1 或 4"));
        }
        let fit = match options.fit {
            MA_FIT_CONTAIN => Fit::Contain,
            MA_FIT_COVER => Fit::Cover,
            _ => return Err(Error::new(MA_INVALID_ARGUMENT, "缩放模式无效")),
        };
        state::with_entry(avatar, |entry| {
            let image = &entry.avatar.package().rig.image;
            let view = ViewOptions {
                image_size: [image.width, image.height],
                pad_top: options.pad_top,
                pad_side: options.pad_side,
                fit,
            };
            view.transform(size).map_err(render_error)?;
            let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
                #[cfg(target_os = "android")]
                backends: wgpu::Backends::VULKAN | wgpu::Backends::GL,
                #[cfg(target_vendor = "apple")]
                backends: wgpu::Backends::METAL,
                ..Default::default()
            });
            #[cfg(target_os = "android")]
            let surface = unsafe { android_surface(&instance, window) }?;
            #[cfg(target_vendor = "apple")]
            let _ = window;
            let adapter =
                pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
                    power_preference: wgpu::PowerPreference::HighPerformance,
                    #[cfg(target_os = "android")]
                    compatible_surface: Some(&surface),
                    #[cfg(target_vendor = "apple")]
                    compatible_surface: None,
                    force_fallback_adapter: false,
                }))
                .map_err(|e| Error::new(MA_GPU_UNAVAILABLE, e.to_string()))?;
            #[cfg(target_os = "android")]
            let caps = surface.get_capabilities(&adapter);
            #[cfg(target_os = "android")]
            let format = [
                wgpu::TextureFormat::Rgba8Unorm,
                wgpu::TextureFormat::Bgra8Unorm,
            ]
            .into_iter()
            .find(|f| caps.formats.contains(f))
            .ok_or_else(|| render_error("窗口不支持线性 RGBA/BGRA"))?;
            #[cfg(target_vendor = "apple")]
            let format = wgpu::TextureFormat::Bgra8Unorm;
            if !adapter
                .get_texture_format_features(format)
                .flags
                .sample_count_supported(options.samples)
            {
                return Err(render_error("GPU 不支持指定的采样数"));
            }
            let (device, queue) =
                pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
                    label: Some("mesh avatar direct output"),
                    ..Default::default()
                }))
                .map_err(render_error)?;
            validate_target(size, &view, &device.limits())?;
            let renderer = Renderer::new(
                &device,
                &queue,
                format,
                options.samples,
                entry.avatar.textures(),
            )
            .map_err(render_error)?;
            #[cfg(target_os = "android")]
            let config = {
                // 预乘透明度和旧输出一致；Inherit 让 Android 合成器按缓冲区透明通道处理。
                let alpha_mode = [
                    wgpu::CompositeAlphaMode::PreMultiplied,
                    wgpu::CompositeAlphaMode::Inherit,
                ]
                .into_iter()
                .find(|a| caps.alpha_modes.contains(a))
                .ok_or_else(|| render_error("窗口不支持透明合成"))?;
                let config = wgpu::SurfaceConfiguration {
                    usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                    format,
                    width: size[0],
                    height: size[1],
                    present_mode: wgpu::PresentMode::Fifo,
                    desired_maximum_frame_latency: 2,
                    alpha_mode,
                    view_formats: vec![],
                };
                surface.configure(&device, &config);
                config
            };
            let id = state::allocate_handle()?;
            entries()
                .lock()
                .map_err(|_| render_error("GPU 注册表已损坏"))?
                .insert(
                    id,
                    Arc::new(Mutex::new(GpuEntry {
                        renderer,
                        device,
                        queue,
                        avatar,
                        size,
                        view,
                        alive: true,
                        #[cfg(target_os = "android")]
                        instance,
                        #[cfg(target_os = "android")]
                        adapter,
                        #[cfg(target_os = "android")]
                        surface: Some(surface),
                        #[cfg(target_os = "android")]
                        config,
                        #[cfg(target_vendor = "apple")]
                        serial: 0,
                        #[cfg(target_vendor = "apple")]
                        completed: Arc::new(AtomicU64::new(0)),
                    })),
                );
            unsafe {
                out.write(id);
            }
            Ok(())
        })
    })
}

impl GpuEntry {
    fn encode(&mut self, target: &wgpu::TextureView) -> Result<wgpu::CommandBuffer> {
        state::with_entry(self.avatar, |avatar| {
            let frame = avatar
                .frame
                .as_ref()
                .ok_or_else(|| Error::new(MA_INVALID_STATE, "角色尚未生成帧"))?;
            let mut encoder = self.device.create_command_encoder(&Default::default());
            self.renderer
                .render(&mut encoder, target, self.size, frame.frame(), &self.view)
                .map_err(render_error)?;
            Ok(encoder.finish())
        })
    }
}

/// 传空解除旧窗口。返回后调用方才可释放旧 ANativeWindow 引用。
#[cfg(target_os = "android")]
#[no_mangle]
pub unsafe extern "C" fn mesh_avatar_gpu_set_surface(
    id: MaRenderer,
    window: *mut c_void,
) -> MaStatus {
    boundary(|| {
        with_gpu(id, |entry| {
            entry.surface = None;
            if !window.is_null() {
                let surface = unsafe { android_surface(&entry.instance, window) }?;
                let caps = surface.get_capabilities(&entry.adapter);
                if !caps.formats.contains(&entry.config.format)
                    || !caps.alpha_modes.contains(&entry.config.alpha_mode)
                {
                    return Err(render_error("新窗口格式不兼容，请重新加载角色"));
                }
                surface.configure(&entry.device, &entry.config);
                entry.surface = Some(surface);
            }
            Ok(())
        })
    })
}

/// 只有成功提交交换链时 presented 才为 1；暂时不可用的窗口跳过本帧。
#[cfg(target_os = "android")]
#[no_mangle]
pub unsafe extern "C" fn mesh_avatar_gpu_draw_surface(
    id: MaRenderer,
    presented: *mut u8,
) -> MaStatus {
    boundary(|| {
        check_out(presented)?;
        unsafe {
            presented.write(0);
        }
        with_gpu(id, |entry| {
            let Some(surface) = &entry.surface else {
                return Ok(());
            };
            let output = match surface.get_current_texture() {
                Ok(output) => output,
                Err(wgpu::SurfaceError::Lost | wgpu::SurfaceError::Outdated) => {
                    surface.configure(&entry.device, &entry.config);
                    return Ok(());
                }
                Err(wgpu::SurfaceError::Timeout) => return Ok(()),
                Err(error) => return Err(render_error(error)),
            };
            let commands = entry.encode(&output.texture.create_view(&Default::default()))?;
            entry.queue.submit([commands]);
            output.present();
            unsafe {
                presented.write(1);
            }
            Ok(())
        })
    })
}

/// 返回借用的 MTLDevice 指针；缓存和纹理必须使用此设备，不能另建默认设备。
#[cfg(target_vendor = "apple")]
#[no_mangle]
pub unsafe extern "C" fn mesh_avatar_gpu_metal_device(
    id: MaRenderer,
    out: *mut *mut c_void,
) -> MaStatus {
    boundary(|| {
        check_out(out)?;
        unsafe {
            out.write(std::ptr::null_mut());
        }
        with_gpu(id, |entry| {
            let device = unsafe { entry.device.as_hal::<wgpu::hal::api::Metal>() }
                .ok_or_else(|| render_error("不是 Metal 设备"))?;
            unsafe {
                out.write(device.raw_device().lock().as_ptr().cast());
            }
            Ok(())
        })
    })
}

/// texture 是有效的 BGRA8、单层、单采样 MTLTexture。调用方保留其 CVPixelBuffer 到完成序号返回。
#[cfg(target_vendor = "apple")]
#[no_mangle]
pub unsafe extern "C" fn mesh_avatar_gpu_draw_metal(
    id: MaRenderer,
    texture: *mut c_void,
    out: *mut u64,
) -> MaStatus {
    boundary(|| {
        check_out(out)?;
        unsafe {
            out.write(0);
        }
        if texture.is_null() {
            return Err(Error::new(MA_INVALID_ARGUMENT, "Metal 纹理为空"));
        }
        with_gpu(id, |entry| {
            // to_owned 增加 Metal 引用，不接管 Swift / CVMetalTexture 持有的那次引用。
            let raw = unsafe { metal::TextureRef::from_ptr(texture.cast()) }.to_owned();
            let device = unsafe { entry.device.as_hal::<wgpu::hal::api::Metal>() }
                .ok_or_else(|| render_error("不是 Metal 设备"))?;
            if raw.device().as_ptr() != device.raw_device().lock().as_ptr()
                || raw.width() != entry.size[0] as u64
                || raw.height() != entry.size[1] as u64
                || raw.pixel_format() != metal::MTLPixelFormat::BGRA8Unorm
                || raw.texture_type() != metal::MTLTextureType::D2
                || raw.sample_count() != 1
            {
                return Err(Error::new(
                    MA_INVALID_ARGUMENT,
                    "共享纹理设备、尺寸或格式不匹配",
                ));
            }
            drop(device);
            let size = wgpu::Extent3d {
                width: entry.size[0],
                height: entry.size[1],
                depth_or_array_layers: 1,
            };
            let hal = unsafe {
                wgpu::hal::metal::Device::texture_from_raw(
                    raw,
                    wgpu::TextureFormat::Bgra8Unorm,
                    metal::MTLTextureType::D2,
                    1,
                    1,
                    size.into(),
                )
            };
            let target = unsafe {
                entry
                    .device
                    .create_texture_from_hal::<wgpu::hal::api::Metal>(
                        hal,
                        &wgpu::TextureDescriptor {
                            label: Some("Flutter IOSurface"),
                            size,
                            mip_level_count: 1,
                            sample_count: 1,
                            dimension: wgpu::TextureDimension::D2,
                            format: wgpu::TextureFormat::Bgra8Unorm,
                            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                            view_formats: &[],
                        },
                    )
            };
            let commands = entry.encode(&target.create_view(&Default::default()))?;
            entry.queue.submit([commands]);
            entry.serial += 1;
            let serial = entry.serial;
            let completed = entry.completed.clone();
            // 只更新原子序号；不在 GPU 回调里调用 Swift，也不持有像素锁。
            entry.queue.on_submitted_work_done(move || {
                completed.fetch_max(serial, Ordering::Release);
            });
            unsafe {
                out.write(serial);
            }
            Ok(())
        })
    })
}

/// 非阻塞推进 GPU 回调，返回已经完成的最后一个提交序号。
#[cfg(target_vendor = "apple")]
#[no_mangle]
pub unsafe extern "C" fn mesh_avatar_gpu_poll(id: MaRenderer, out: *mut u64) -> MaStatus {
    boundary(|| {
        check_out(out)?;
        with_gpu(id, |entry| {
            entry
                .device
                .poll(wgpu::PollType::Poll)
                .map_err(render_error)?;
            unsafe {
                out.write(entry.completed.load(Ordering::Acquire));
            }
            Ok(())
        })
    })
}

/// 只在关闭时等待 GPU 任务释放，不在逐帧路径阻塞回读。
#[no_mangle]
pub extern "C" fn mesh_avatar_gpu_destroy(id: MaRenderer) -> MaStatus {
    boundary(|| {
        let shared = entries()
            .lock()
            .map_err(|_| render_error("GPU 注册表已损坏"))?
            .remove(&id)
            .ok_or_else(|| Error::new(MA_INVALID_HANDLE, "GPU 句柄无效"))?;
        let mut entry = shared
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        entry.alive = false;
        entry
            .device
            .poll(wgpu::PollType::Wait {
                submission_index: None,
                timeout: Some(std::time::Duration::from_secs(5)),
            })
            .map_err(render_error)?;
        Ok(())
    })
}

#[cfg(all(test, target_vendor = "apple"))]
#[path = "direct_tests.rs"]
mod tests;
