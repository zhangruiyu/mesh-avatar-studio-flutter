//! Flutter 共用的运行控制协议。三端只传输 JSON，校验和行为在此保持一致。
use crate::{
    boundary::{boundary, check_out, input_str, Error, Result},
    state,
    types::*,
};
use mesh_avatar_core::engine::{
    kana::Vowel, lip_sync::LipSyncSettings, motion::SpeakOptions, rig::PARAMS,
};
use mesh_avatar_core::rig::ClothTuningUpdate;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    ffi::{c_char, CString},
};

#[derive(Deserialize)]
#[serde(tag = "method", rename_all = "camelCase", deny_unknown_fields)]
enum Request {
    Metadata {},
    State {},
    Parameters {
        values: BTreeMap<String, f64>,
        weight: f64,
    },
    Emotion {
        name: String,
        #[serde(rename = "playMotion")]
        play_motion: bool,
    },
    Motion {
        name: String,
    },
    Overlays {
        names: Vec<String>,
    },
    LipSync {
        settings: Value,
    },
    SpeakKana {
        text: String,
        speed: Option<f64>,
        #[serde(rename = "loop")]
        looping: bool,
    },
    HoldMouth {
        vowel: String,
    },
    StopLipSync {},
    AutoIdle {
        enabled: bool,
    },
    AutoMotion {
        enabled: bool,
    },
    TalkGain {
        gain: f64,
    },
    SwayGain {
        gain: f64,
    },
    Cloth {
        name: Option<String>,
        values: ClothTuningUpdate,
    },
}
fn invalid(message: impl ToString) -> Error {
    Error::new(MA_INVALID_ARGUMENT, message.to_string())
}
fn range(value: f64, min: f64, max: f64) -> Result<()> {
    if value.is_finite() && (min..=max).contains(&value) {
        Ok(())
    } else {
        Err(invalid(format!("数值必须在 {min} 到 {max} 之间")))
    }
}
fn execute(entry: &mut state::Entry, request: Request) -> Result<Value> {
    let a = &mut entry.avatar;
    match request {
        Request::Metadata {} => {
            let mut params = serde_json::to_value(PARAMS).map_err(invalid)?;
            params.as_array_mut().unwrap().push(
                json!({"id":"eyeSmileL","label":"左眼笑意","min":0,"max":1,"def":0,"group":"eyes"}),
            );
            return Ok(
                json!({"motions":a.motions().iter().map(|m| json!({"id":m.id,"label":m.label,"duration":m.dur,"idle":m.idle})).collect::<Vec<_>>(),
                "parameters":params,
                "overlays":a.package().overlays.as_ref().map(|o| o.overlays.iter().map(|o| &o.name).collect::<Vec<_>>()).unwrap_or_default(),
                "garments":a.package().rig.cloth.iter().map(|c| &c.name).collect::<Vec<_>>() }),
            );
        }
        Request::State {} => {
            let mut value = a.control_state();
            value["motionEvents"] = json!(entry.events.drain(..).collect::<Vec<_>>());
            return Ok(value);
        }
        Request::Parameters { values, weight } => {
            range(weight, 0.0, 1.0)?;
            if values.len() > 128 {
                return Err(invalid("参数数量过多"));
            }
            // 先验证整批，避免第二个参数非法时第一个已经生效。
            for (name, value) in &values {
                let (min, max) = PARAMS
                    .iter()
                    .find(|p| p.id == name)
                    .map(|p| (p.min, p.max))
                    .or_else(|| (name == "eyeSmileL").then_some((0.0, 1.0)))
                    .ok_or_else(|| invalid(format!("未知参数：{name}")))?;
                range(*value, min, max)?;
            }
            a.set_parameters_weighted(values, weight);
        }
        Request::Emotion { name, play_motion } => {
            if !["neutral", "happy", "sad", "angry", "surprised", "relaxed"]
                .contains(&name.as_str())
            {
                return Err(invalid("未知情绪"));
            }
            a.set_emotion_with_motion(&name, play_motion);
        }
        Request::Motion { name } => {
            if !a.motions().iter().any(|m| m.id == name) {
                return Err(invalid("未知动作"));
            }
            a.play(&name);
        }
        Request::Overlays { names } => {
            if names.len() > 200 {
                return Err(invalid("配饰数量过多"));
            }
            a.set_overlays(&names.iter().map(String::as_str).collect::<Vec<_>>());
        }
        Request::LipSync { settings } => {
            if settings.as_object().is_none_or(|o| {
                o.keys()
                    .any(|k| !["granularity", "openness", "closeSpeed"].contains(&k.as_str()))
            }) {
                return Err(invalid("未知口型设置"));
            }
            a.set_lip_sync(&LipSyncSettings::parse(&settings).map_err(invalid)?)
                .map_err(invalid)?;
        }
        Request::SpeakKana {
            text,
            speed,
            looping,
        } => {
            if let Some(speed) = speed {
                range(speed, 4.0, 12.0)?;
            }
            a.speak_kana(&text, SpeakOptions { speed, looping });
        }
        Request::HoldMouth { vowel } => {
            a.hold_mouth(Vowel::parse(&vowel).ok_or_else(|| invalid("未知元音"))?)
        }
        Request::StopLipSync {} => a.stop_lip_sync(),
        Request::AutoIdle { enabled } => a.set_auto_idle(enabled),
        Request::AutoMotion { enabled } => a.set_auto_motion(enabled),
        Request::TalkGain { gain } => {
            range(gain, 0.0, f64::MAX)?;
            a.set_talk_gain(gain);
        }
        Request::SwayGain { gain } => {
            range(gain, 0.0, f64::MAX)?;
            a.set_sway_gain(gain);
        }
        Request::Cloth { name, values } => a
            .set_cloth_tuning(name.as_deref(), &values)
            .map_err(invalid)?,
    }
    Ok(Value::Null)
}
/// 执行运行控制并返回独立分配的 UTF-8 JSON，调用方用 mesh_avatar_free_string 释放。
/// 失败时输出置空；不改变旧 C ABI。请求最大 64 KiB。
/// # Safety
/// request 必须是有效的 NUL 结尾字符串；out 必须可写且对齐。
#[no_mangle]
pub unsafe extern "C" fn mesh_avatar_control_json(
    handle: MaHandle,
    request: *const c_char,
    out: *mut *mut c_char,
) -> MaStatus {
    boundary(|| {
        check_out(out)?;
        // 调用方保证输出槽和输入字符串有效，返回字符串独立于角色生命周期。
        unsafe {
            out.write(std::ptr::null_mut());
        }
        let request = unsafe { input_str(request) }?;
        if request.len() > 65536 {
            return Err(invalid("请求超过 64 KiB"));
        }
        let request: Request = serde_json::from_str(request).map_err(invalid)?;
        let value = state::with_entry(handle, |entry| execute(entry, request))?;
        let result = CString::new(value.to_string()).map_err(invalid)?;
        unsafe {
            out.write(result.into_raw());
        }
        Ok(())
    })
}
/// 释放本模块返回的字符串，允许 NULL；同一个指针只能释放一次。
/// # Safety
/// 非空指针必须由 mesh_avatar_control_json 返回，且尚未释放。
#[no_mangle]
pub unsafe extern "C" fn mesh_avatar_free_string(text: *mut c_char) {
    if !text.is_null() {
        drop(unsafe { CString::from_raw(text) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::*;
    use std::ffi::CStr;
    struct Model(MaHandle);
    impl Drop for Model {
        fn drop(&mut self) {
            assert_eq!(mesh_avatar_destroy(self.0), MA_OK);
        }
    }
    fn model() -> Model {
        // 只在测试进程读取官方示例，生产库不嵌入任何角色字节。
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../../example/assets/miko/miko-qipao.mavatar");
        let path = CString::new(path.to_str().unwrap()).unwrap();
        let mut handle = 0;
        assert_eq!(
            unsafe { mesh_avatar_open_path(path.as_ptr(), &mut handle) },
            MA_OK
        );
        Model(handle)
    }
    fn call(model: &Model, value: Value) -> Value {
        let input = CString::new(value.to_string()).unwrap();
        let mut out = std::ptr::null_mut();
        let status = unsafe { mesh_avatar_control_json(model.0, input.as_ptr(), &mut out) };
        assert_eq!(
            status,
            MA_OK,
            "{}",
            unsafe { CStr::from_ptr(mesh_avatar_last_error()) }.to_string_lossy()
        );
        let result =
            serde_json::from_str(unsafe { CStr::from_ptr(out) }.to_str().unwrap()).unwrap();
        unsafe { mesh_avatar_free_string(out) };
        result
    }
    fn reject(model: &Model, value: Value) {
        let input = CString::new(value.to_string()).unwrap();
        let mut out = std::ptr::dangling_mut();
        assert_eq!(
            unsafe { mesh_avatar_control_json(model.0, input.as_ptr(), &mut out) },
            MA_INVALID_ARGUMENT,
            "请求应拒绝：{value}"
        );
        assert!(out.is_null());
    }
    #[test]
    fn controls_overlays_and_cloth_use_real_runtime_state() {
        use mesh_avatar_core::{
            format::{AvatarPackage, OverlayDefinition, OverlayMetadata},
            Avatar,
        };
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../../example/assets/miko/miko-qipao.mavatar");

        // 合成测试夹具只在内存中复用已有纹理，绝不改写或打包示例模型。
        let mut package = AvatarPackage::from_archive(std::fs::File::open(path).unwrap()).unwrap();
        let texture = package.textures.values().next().unwrap().clone();
        package.textures.insert("overlays/test.png".into(), texture);
        package.overlays = Some(OverlayMetadata {
            version: 1,
            overlays: vec![OverlayDefinition {
                name: "测试配饰😊".into(),
                file: "test.png".into(),
            }],
        });
        package.textures.insert(
            "base_cloth.png".into(),
            package.textures["base.png"].clone(),
        );
        package.textures.insert(
            "cloth_test_cloth.png".into(),
            package.textures["base.png"].clone(),
        );
        package.layers.layers.insert(
            "cloth_test_cloth".into(),
            [0, 0, package.rig.image.width, package.rig.image.height],
        );
        package.rig.cloth.push(serde_json::from_value(json!({"name":"test_cloth","outline":[[100,400],[500,400],[500,700],[100,700]],"waist":[[100,400],[500,400]],"hem":[[100,700],[500,700]]})).unwrap());
        let m = Model(
            state::insert(
                state::Entry::new(Avatar::from_package(package).unwrap())
                    .unwrap_or_else(|e| panic!("{}", e.message)),
            )
            .unwrap_or_else(|e| panic!("{}", e.message)),
        );
        let meta = call(&m, json!({"method":"metadata"}));
        assert_eq!(meta["overlays"], json!(["测试配饰😊"]));
        let mut before = unsafe { std::mem::zeroed::<MaFrame>() };
        assert_eq!(unsafe { mesh_avatar_get_frame(m.0, &mut before) }, MA_OK);
        call(
            &m,
            json!({"method":"overlays","names":["测试配饰😊","不存在"]}),
        );
        mesh_avatar_tick(m.0, 0.03);
        let mut after = unsafe { std::mem::zeroed::<MaFrame>() };
        assert_eq!(unsafe { mesh_avatar_get_frame(m.0, &mut after) }, MA_OK);
        assert_eq!(after.layer_count, before.layer_count + 1);
        assert_eq!(
            call(&m, json!({"method":"state"}))["overlays"],
            json!(["测试配饰😊"])
        );
        call(&m, json!({"method":"overlays","names":[]}));
        mesh_avatar_tick(m.0, 0.03);
        assert_eq!(call(&m, json!({"method":"state"}))["overlays"], json!([]));
        call(
            &m,
            json!({"method":"cloth","name":"test_cloth","values":{"follow":0.2,"damping":1.3}}),
        );
        reject(
            &m,
            json!({"method":"cloth","name":"test_cloth","values":{"follow":0.5,"damping":-1}}),
        );
        let tuning = call(&m, json!({"method":"state"}))["clothTuning"]["test_cloth"].clone();
        assert_eq!(tuning["follow"], 0.2);
        assert_eq!(tuning["damping"], 1.3);
    }
    #[test]
    fn controls_parameters_atomic_and_metadata() {
        let m = model();
        let meta = call(&m, json!({"method":"metadata"}));
        assert_eq!(meta["motions"].as_array().unwrap().len(), 21);
        assert_eq!(meta["parameters"].as_array().unwrap().len(), 25);
        call(
            &m,
            json!({"method":"parameters","values":{"angleX":12,"gazeY":0.5},"weight":0.7}),
        );
        reject(
            &m,
            json!({"method":"parameters","values":{"angleX":4,"gazeY":5},"weight":1}),
        );
        let s = call(&m, json!({"method":"state"}));
        assert_eq!(s["overrides"]["angleX"], 12.0);
        assert_eq!(s["weight"], 0.7);
        reject(
            &m,
            json!({"method":"parameters","values":{"unknown":1},"weight":1}),
        );
        call(&m, json!({"method":"parameters","values":{},"weight":1}));
        assert_eq!(call(&m, json!({"method":"state"}))["overrides"], json!({}));
    }
    #[test]
    fn controls_lip_settings_modes_and_invalid_requests() {
        let m = model();
        call(&m, json!({"method":"lipSync","settings":{"openness":0.8}}));
        reject(
            &m,
            json!({"method":"lipSync","settings":{"openness":0.1,"closeSpeed":2}}),
        );
        assert_eq!(
            call(&m, json!({"method":"state"}))["lipSync"]["openness"],
            0.8
        );
        for vowel in ["a", "i", "u", "e", "o", "n"] {
            call(&m, json!({"method":"holdMouth","vowel":vowel}));
            mesh_avatar_tick(m.0, 0.03);
            assert_eq!(call(&m, json!({"method":"state"}))["mouth"]["active"], true);
        }
        call(
            &m,
            json!({"method":"speakKana","text":"こんにちは😊","speed":8,"loop":true}),
        );
        call(&m, json!({"method":"stopLipSync"}));
        assert_eq!(
            call(&m, json!({"method":"state"}))["mouth"]["active"],
            false
        );
        for bad in [
            json!({"method":"motion","name":"missing"}),
            json!({"method":"swayGain","gain":-1}),
            json!({"method":"cloth","values":{"follow":2}}),
            json!({"method":"cloth","values":{"typo":1}}),
            json!({"method":"state","typo":1}),
        ] {
            reject(&m, bad);
        }
    }
    #[test]
    fn controls_motion_events_include_completion_and_are_bounded() {
        let m = model();
        call(&m, json!({"method":"autoIdle","enabled":false}));
        call(&m, json!({"method":"autoMotion","enabled":false}));
        for motion in call(&m, json!({"method":"metadata"}))["motions"]
            .as_array()
            .unwrap()
        {
            call(&m, json!({"method":"motion","name":motion["id"]}));
            for _ in 0..((motion["duration"].as_f64().unwrap() / 0.05).ceil() as usize + 2) {
                assert_eq!(mesh_avatar_tick(m.0, 0.05), MA_OK);
            }
            let events = call(&m, json!({"method":"state"}))["motionEvents"].clone();
            assert!(events.as_array().unwrap().contains(&motion["id"]));
            assert!(events.as_array().unwrap().contains(&Value::Null));
        }
        for _ in 0..270 {
            call(&m, json!({"method":"motion","name":"nod"}));
            mesh_avatar_tick(m.0, 0.01);
        }
        assert_eq!(
            call(&m, json!({"method":"state"}))["motionEvents"]
                .as_array()
                .unwrap()
                .len(),
            256
        );
        assert_eq!(
            call(&m, json!({"method":"state"}))["motionEvents"],
            json!([])
        );
    }
}
