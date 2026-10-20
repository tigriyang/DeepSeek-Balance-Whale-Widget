# 素材来源与许可

这份说明只管**发版 DMG 里带的素材**，不改变代码的 MIT 许可。

## 一、DMG 里带了什么

发布的 `WhaleFloat.dmg` 为了开箱能用，带上了默认角色与音效：

```
Contents/Resources/DSniang02.png     备用整图
Contents/Resources/DSniang1.png      备用整图
Contents/Resources/role-clean.png    默认角色（去泡版）
Contents/Resources/press-down.mp3    按下音
Contents/Resources/press-up.mp3      松开音
Contents/Resources/AppIcon.icns      应用图标
```

**仓库本身不含这些文件**（`.gitignore` 排除 `Resources/*.png`、`*.mp3`、`*.icns`），
只有本机构建时它们才在包内。也就是说：源码仓库是干净的，DMG 是带素材的。

## 二、来源与权利状态

这些素材来自上游项目
[MeteorNOX/DeepSeek-Balance-Whale-Widget](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget)
的 `assets/`。上游的
[PROVENANCE.md](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget/blob/main/PROVENANCE.md)
写明：

- 图片由 AI 工具生成，经人工挑选与裁切，生成工具与原始出处已不可考；
- 美术素材**不在 MIT 覆盖范围内**，按 **as-is** 随插件分发，**仅用于运行本插件**；
- **不授予再许可**，也**不声明为原创作品**；
- 收到权利主张会立即替换或移除。

“AI 生成、出处不可考”只说明难以举证，**不等于没有权利人**。
角色形象若涉及上游 IP，其权利也不因为二次创作而消失。
本项目不声称对这些素材拥有版权，只按上游的 as-is 条款随应用一并提供。

## 三、如果你要再分发

- 自己重新打包再分发时，请保留这份说明，并自行评估风险；
- 最稳妥的做法是换上你有权分发的素材（自己画的、买断的、或模型生成且许可清晰的）；
- 也可以不带素材发布：应用在缺素材时会退化成“只有状态栏图标”，
  用户可用「桌宠设置 → 获取仓库素材…」自行导入。

## 四、权利主张

如果你认为这里有素材侵犯了你的权利，请在本仓库开 issue，
说明文件名与依据，核实后会立即替换或移除，不附加其它条件。
