Miko Mesh Avatar (Qipao)

Overview
--------
This package contains a .mavatar file of Miko in a qipao, built as a 2D mesh
avatar with Mesh Avatar Studio.

The file bundles the rig for blinking, lip sync, head movement, breathing,
and hair sway, together with expression and mouth-shape sprites. Load it into
the AITuber OnAir mesh avatar example and Miko moves along with the voice.

Contents
--------
- miko-qipao.mavatar
  - Mesh Avatar Studio format (format: mesh-avatar / version 1)
  - 1254 x 1254 px source illustration, rig, and expression/mouth sprites
  - Includes drawn sad and surprised eyes and angry and sad closed mouths
    (shown for those emotions with mesh-avatar 0.2.0 or later)
- README_en.txt (this file)
- README_ja.txt (Japanese version)
- MIKO_ASSET_TERMS.md (short English summary of the terms)

Using it with AITuber OnAir
---------------------------
The file works with the mesh avatar example:
https://github.com/shinshin86/aituber-onair/tree/main/packages/core/examples/react-mesh-avatar-app

1. Extract the ZIP file.
2. Start the example, open Settings -> "アバター・モーション" (Avatar & Motion)
   -> "アバター" (Avatar), and choose miko-qipao.mavatar with
   "ファイルを選択" (Choose file).

The example already ships the same miko-qipao.mavatar as its default avatar.

Making your own avatar
----------------------
.mavatar files are created and edited with Mesh Avatar Studio, an open-source
tool published on GitHub. It turns a single illustration into an avatar in the
same format. If you want to build one for your own character, take a look:
Repository: https://github.com/shinshin86/mesh-avatar-studio
Project page: https://shinshin86.github.io/mesh-avatar-studio/

Notes
-----
- A .mavatar file is a ZIP archive of images and JSON. Do not extract the
  images and redistribute them as standalone assets (see the terms below).
- Updates to Mesh Avatar Studio or the runtime may change how the avatar
  looks or moves.

Terms
-----
The authoritative Japanese Miko Character Usage Guidelines apply to this
package. The bundled MIKO_ASSET_TERMS.md is a short English summary;
translations are for reference only:
https://miko.aituberonair.com/#terms

Commercial use is allowed, use is free of charge, and credit is optional.
The asset may be redistributed as an integral part of software, apps, games,
videos, websites, or other works and content. Standalone redistribution,
asset collections, and distributions primarily intended to provide the asset
are prohibited. Do not imply official affiliation or claim ownership or
exclusive rights to Miko.

Credit (optional)
-----------------
© Yuki Shindo (AITuber OnAir)

Miko is the official character of AITuber OnAir.

Source:
https://github.com/shinshin86/aituber-onair/tree/main/packages/core/examples/react-mesh-avatar-app/public/avatar
Source commit: 2b3d892661e0c4bc17dc766722ba4b8b3431190b
