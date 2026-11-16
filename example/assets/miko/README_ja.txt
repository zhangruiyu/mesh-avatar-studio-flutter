ミコ メッシュアバター（チャイナドレス）

概要
----
このパッケージには、チャイナドレス姿のミコを Mesh Avatar Studio で
2Dメッシュアバターにした .mavatar ファイルが含まれています。

まばたき・口パク・首振り・呼吸・髪の揺れなどのリグと、表情・口の形の
差分画像を1つのファイルにまとめています。AITuber OnAirのメッシュアバター
サンプルに読み込むと、音声に合わせてミコが動きます。

収録内容
--------
- miko-qipao.mavatar
  - Mesh Avatar Studio 形式（format: mesh-avatar / version 1）
  - 元イラスト 1254 x 1254 px、リグ、表情・口の差分スプライトを収録
  - 悲しみ・驚きの目と、怒り・悲しみの閉じた口の差分も収録
    （感情に合わせた切り替えは mesh-avatar 0.2.0 以降で表示されます）
- README_ja.txt（このファイル）
- README_en.txt（英語版）
- MIKO_ASSET_TERMS.md（英語による利用条件の概要）

AITuber OnAirで使う
-------------------
以下のメッシュアバターサンプルで利用できます。
https://github.com/shinshin86/aituber-onair/tree/main/packages/core/examples/react-mesh-avatar-app

1. ZIPファイルを展開します。
2. サンプルを起動し、Settings →「アバター・モーション」→「アバター」の
   「ファイルを選択」で miko-qipao.mavatar を選びます。

このサンプルには、同じ miko-qipao.mavatar が既定のアバターとして
同梱されています。

自分のアバターを作りたい場合
----------------------------
.mavatar は Mesh Avatar Studio で作成・編集できます。Mesh Avatar Studio は
GitHubで公開しているオープンソースのツールで、1枚のイラストから同じ形式の
アバターを作れます。自分のキャラクターで作りたい方はこちらもご覧ください。
リポジトリ: https://github.com/shinshin86/mesh-avatar-studio
紹介ページ: https://shinshin86.github.io/mesh-avatar-studio/ja/

注意事項
--------
- .mavatar の中身は画像とJSONをまとめたZIP形式です。中の画像を取り出して
  素材単体として再配布することはできません（利用条件を参照）。
- Mesh Avatar Studio やランタイムの更新によって、表示や動作が変わる
  場合があります。

利用条件
--------
このパッケージには、ミコ キャラクター利用ガイドラインが適用されます。
正式版は日本語版です。利用前に以下をご確認ください。
https://miko.aituberonair.com/#terms

商用利用は可能、利用料は無料、クレジット表記は任意です。
ソフトウェア、アプリ、ゲーム、映像、Webサイトその他の作品・コンテンツの
一部として、それらと一体で再配布できます。素材単体・素材集としての再配布や、
素材提供を主目的とする配布は禁止です。公式・提携を装ったり、ミコの権利や
独占的な利用権を主張したりすることはできません。

クレジット（任意）
------------------
© Yuki Shindo (AITuber OnAir)

ミコはAITuber OnAirの公式キャラクターです。

Source:
https://github.com/shinshin86/aituber-onair/tree/main/packages/core/examples/react-mesh-avatar-app/public/avatar
Source commit: 2b3d892661e0c4bc17dc766722ba4b8b3431190b
