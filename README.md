# AI错题本 (AI Wrong Notebook) · 自用优化版

> **Fork 说明与致谢**  
> 本仓库 Fork 自原作者 [@tjunsh](https://github.com/tjunsh) 的开源项目 [tjunsh/ai-wrong-notebook](https://github.com/tjunsh/ai-wrong-notebook)。  
> 非常感谢原作者做出这么实用、架构扎实的开源错题本应用！本分支在原项目基础上结合日常使用场景持续打磨与优化，目的是**让我自家孩子用起来更顺手、更高效**。  
> 下方完整保留原作者的原版说明与赞赏渠道，如项目帮到了你，欢迎前往原仓库点 Star 并支持原作者。
>
> **本分支安装包下载**：[Releases · jinzong8/ai-wrong-notebook](https://github.com/jinzong8/ai-wrong-notebook/releases)  
> **当前自用模型**：`gpt6.1-terra`（基于 OpenAI 新版接口协议实测稳定可用）

## 本分支更新日志

### v1.0.12
- **连续刷题复习流与遮挡答案自测（Active Recall）**：复习页新增 **「开始连续复习」** 主入口（点任意待复习题亦串联队列）并消除嵌套滚动卡顿；复习态默认遮挡答案与解题步骤，先独立思考再点「查看答案与解析」，打卡「仍需复习 / 已掌握」后自动切入下一题并实时轮转 `lastReviewedAt` 队列。
- **题目不清「重拍原地换图 + 修改题干」双通道**：在详情页、解析结果页与核对题干页统一提供「重新拍照」与「修改题干」入口；支持原地替换模糊/裁断原图并自动清理旧废图，保留原录入时间、标签与复习进度，不产生重复错题。
- **错题本排序筛选升级与详情页改科目 / 删标签**：错题本默认最新录入在前，支持「最新 / 最早 / 复习最多」排序切换、掌握状态筛选与有题科目优先计数展示，修复点击标签筛选为空的问题；详情页支持**点击科目胶囊修改科目**、**点击 `×` 删除自定义标签**，AI 答疑发送失败自动回滚不丢字。
- **举一反三练习修复与「回看本组」复盘**：修复带前缀/小写选项匹配、纯数字选项题号撞车、填空作答提交后消失及中途退出丢进度问题；支持切题与完成后点击任意题**回看解析**。
- **底层持久化、防死灰复燃与自然日统计修复**：知识点/标签改为 JSON 数组无损存储（不再被数学区间逗号切碎），复习记录统一无损迁入 SQLite 并实时刷新；修复删除后台任务后仍自动入库的竞态、自定义提示词覆盖 JSON 协议的问题（改为安全追加 + 恢复默认），以及跨午夜「今日新增」刷新与「今天 / 昨天 HH:mm」自然日显示。

### v1.0.11
- **拍后定格双指缩放与地图式多边形无痕抠题**：定格框选支持 `0.5× ~ 5.0×` 双指焦点缩放平移（含一键「还原」）；放大至 `1.15×` 自动唤醒多边形节点（也可点左上角「多边形」胶囊手动切换），支持拖边中点 `+` 增点（最多 16 点）、双击或胶囊删点、拖点贴边 60fps 自动滚屏，并自动采样卷面纸张底色无痕遮罩排除穿插排版的相邻干扰题。
- **错题详情页精简重构与连续拍题闭环**：精简详情页冗余按钮与说明文案，将卡片调整为「原题 → 正确答案 → 解题步骤 → 错因分析 → 学习建议 → 知识点」；录题保存后底部常驻「继续拍下一题」直拉相机（AI 解析等待页同步提供「后台解析，继续拍下一题」），复习流保留底部打卡自动返回，日常浏览态改为文末轻量切换掌握状态。
- **GitHub 官方源静默断点续传自动更新**：纯走 GitHub 官方 Release 源，后台静默检测并基于 HTTP `Range` + `If-Range` 断点续传预下载，在后台 Isolate 完成字节长度、APK 文件头与官方 `sha256` 摘要三重校验；连不上或未下完时完全静默不弹窗、不影响正常使用，准备就绪后在下次启动或点击「设置 → 关于与更新 → 检查更新」时一键覆盖安装，升级完成后自动清理安装包。

### v1.0.10
- **全面修复安卓系统手势返回**：全应用 12 个业务页统一接入返回拦截并记录真实来源页（侧滑不再误关闭 App；框选阶段侧滑自动重拍，错题详情/拍照页侧滑准确返回原入口页）。
- **底部主 Tab 防误退**：在「错题本 / 复习 / 设置」页侧滑先切回首页，在首页侧滑提示「再返回一次退出应用」，2 秒内再滑一次才退出。
- **首页「拍照录题」移至底部拇指区**：精简首页顶部大卡片，仅保留简洁标题头，将「拍照录题」固定在底部 TabBar 上方作为单手易达的悬浮胶囊主按钮，首屏内容更清爽、单手操作更顺手。

### v1.0.9
- **单题自动入库**：AI 识别结果仅包含 1 道题时，解析完成后直接自动保存到错题本并跳转详情页（前台与后台排队均生效），省去多余的「拆分保存」确认步骤，也不再给单题打上「拍照批次 · 第 1 题」标签。
- **多题保留拆分保存**：一次拍到多道题时，仍完整保留逐题查看与「拆分保存」流程。
- **详情页原地重解析**：错题详情页（含 AI 提示需核对的场景及顶部菜单）新增「核对题干后重新解析」，修正题干后直接原地更新同一条错题，保留标签与复习记录。
- **UI 视觉重构（「纸质习题本 · 深墨钴蓝」）**：统一浅色暖纸 / 深色深墨视觉体系，优化首页、统计卡片、解析进度、错题详情、多题结果与拆分确认页面的层级与可读性。

### v1.0.8
- **拍后所见即所得取景**：放弃易框偏的自动框选，拍照后保持 100% 全宽画面并直接沿用拍照时瞄准的区域，再按需手动微调即可。
- **深色拍照页导航栏图标修复**：修正拍照裁剪页深色背景下的导航栏图标对比度。

### v1.0.7
- **直达拍题框选页**：点击「拍照录题」跳过来源弹窗，直接进入拍照框选界面（页内仍支持切换相册选图）。
- **全宽 4:1 单题取景框**：拍照画面与引导框改为 100% 全宽（约 4:1 比例），直观引导一次拍清一道题。
- **照片角度拉直**：补回照片旋转/角度微调能力，歪拍题目也能快速拉正裁剪。

### v1.0.6
- **支持 OpenAI 新模型与新版协议**：新增对 OpenAI Responses API 及新版 Chat Completions 格式的兼容支持，可顺利对接最新一代多模态 / 推理模型（如目前自用的 `gpt6.1-terra`）。
- **应用内拍照与即时框选**：新增应用内一体拍照框选页面，缩短拍题操作链路。
- **自动化发布流程与固定签名**：接入 GitHub Actions 自动构建正式版 APK/AAB，并配置持久化签名密钥，后续版本可直接覆盖安装、不丢失本地错题数据。

---

# AI错题本 (AI Wrong Notebook)

一款面向学生的智能错题管理应用，把拍题、解析、保存、追问和练习串成完整学习闭环。

<p align="center">
  <a href="https://github.com/tjunsh/ai-wrong-notebook/actions/workflows/ci.yml">
    <img src="https://github.com/tjunsh/ai-wrong-notebook/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI status" />
  </a>
  <a href="https://github.com/tjunsh/ai-wrong-notebook/actions/workflows/release.yml">
    <img src="https://github.com/tjunsh/ai-wrong-notebook/actions/workflows/release.yml/badge.svg" alt="Release status" />
  </a>
  <a href="https://github.com/tjunsh/ai-wrong-notebook/releases/latest">
    <img src="https://img.shields.io/github/v/release/tjunsh/ai-wrong-notebook?display_name=tag&sort=semver" alt="Latest release" />
  </a>
  <img src="https://img.shields.io/badge/platform-Android-3ddc84?logo=android&logoColor=white" alt="Android" />
  <img src="https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white" alt="Flutter" />
  <img src="https://img.shields.io/badge/Dart-0175C2?logo=dart&logoColor=white" alt="Dart" />
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-3da639" alt="MIT License" />
  </a>
</p>

## 功能特性

### 核心功能
- **拍照录题** - 使用相机或相册快速录入错题，支持框选裁剪
- **AI 视觉分析** - AI 直接分析错题图片，识别科目、题干、答案、关键步骤、错因和知识点
- **连续扫题与排队解析** - 当前题解析中仍可继续拍题；任务在后台按顺序处理，避免并发请求和重复消耗
- **多题逐题解析** - 一张图片中的独立题目分别解析、分别保存，避免不同题目的答案和知识点混在一起
- **失败题单独重试** - 多题中某一题失败时，已成功题保持不变；可在原结果页只重试失败题
- **保存或放弃** - 解析后可选择保存到错题本或直接放弃；部分成功时只允许保存已经解析成功的题目
- **AI 自动打标** - 自动生成短标签（如"压强"、"力学"）和详细知识点
- **AI 追问** - 在已保存错题详情中继续提问，追问记录随题目保存
- **举一反三** - 根据错题生成针对性练习，完成一轮后可继续生成新题
- **间隔复习** - 基于记忆曲线安排复习计划
- **学习统计** - 掌握进度可视化（柱状图 + 统计卡片）

### v1.0.5 更新
- **严格任务队列** - 连续扫描多张图片时，AI 请求按顺序执行；用户可以离开解析页继续录题，不会并发消耗多个请求。
- **多题结果可补全** - 部分成功的扫描结果保留在同一张任务卡中，失败题可逐题重试，不会产生重复任务或重复解析成功题。
- **结果更可控** - 未保存的扫描结果可直接放弃；保存时会过滤失败题，并在部分成功时要求确认。
- **配置向导优化** - 可选择服务商预设自动填写 Base URL，获取可用模型后选择模型，并在保存前测试连接；仍支持自定义 OpenAI 兼容接口。
- **本地任务维护** - 支持导出失败日志、清理历史任务和一键清空本地题库及排队任务。

### 用户界面
- Material Design 3 设计语言
- 支持浅色模式 / 深色模式 / 跟随系统
- 流畅的页面切换动画

## 技术栈

| 分类 | 技术 |
|------|------|
| 框架 | Flutter 3.4+ |
| 状态管理 | Riverpod |
| 路由 | GoRouter |
| 本地数据库 | Drift (SQLite) |
| 轻量存储 | SharedPreferences |
| 网络请求 | Dio |
| 主题方案 | flex_color_scheme |
| 图表 | fl_chart |
| AI 服务 | 兼容 OpenAI 格式 API 的多模态模型 |
| 图片选择 | image_picker |
| 图片裁剪 | image_cropper |
| 数据导入导出 | share_plus + file_picker |
| 本地通知 | flutter_local_notifications |
| 安全存储 | flutter_secure_storage |
| 序列化 | json_annotation + json_serializable |
| ID 生成 | uuid |
| 国际化 | intl |

## 项目结构

```
lib/
├── app/                  # 应用入口、路由、主题
├── common/widgets/       # 通用组件
├── data/                 # 数据层
│   ├── files/           # 文件存储
│   ├── remote/ai/       # AI 分析服务
│   ├── repositories/    # 数据仓库（Drift + SharedPreferences）
│   └── services/        # 服务（拍照、存储、通知等）
├── domain/models/       # 领域模型
└── features/           # 功能模块
    ├── analysis/        # AI 分析（加载 + 结果展示）
    ├── capture/         # 拍照录题（裁剪、预览）
    ├── exercise/        # 举一反三练习
    ├── home/            # 首页
    ├── notebook/        # 错题本（列表 + 详情）
    ├── onboarding/      # 引导页
    ├── review/          # 间隔复习
    └── settings/        # 设置（AI配置、数据管理）
```

## 开发

### 环境要求
- Flutter SDK >= 3.4.0
- Android SDK

### 安装依赖
```bash
flutter pub get
```

### 运行
```bash
flutter run
```

### 构建 APK
```bash
flutter build apk --release
```

发布构建需要在本地创建并妥善保管 `android/key.properties` 和签名 keystore；两者均已被 Git 忽略，不应提交到仓库。

### 测试
```bash
flutter test
```

## AI 服务配置

应用支持配置任意 OpenAI 兼容格式的 AI 服务。用于拍照识题的模型必须支持 Vision/图片输入：

1. 进入「设置」→「AI 服务商配置」，选择服务商预设或「自定义」。
2. 预设会自动填写 Base URL；填写 API Key 后可获取模型列表并选择模型。自定义服务可手动填写 Base URL 和模型名称。
3. 点击「保存并测试」，连接通过后即可使用。

不同服务商的模型能力和稳定性不同，请以实际的图片识题测试结果为准。

## 鸣谢

感谢 [Dohoya.com](https://www.dohoya.com/sign-up?aff=hiUV)  
感谢 [Vbcode.io](https://vbcode.io/sign-up?aff=lEmu)

对 AI错题本项目的大模型 API 支持。 
本项目的 AI 视觉分析能力基于兼容 OpenAI API 格式的多模态模型，用户可在应用内自行配置 API 地址、API Key 和模型名称。

> 本项目不内置 API Key，也不绑定特定服务商；<br>
> [dohoya.com]和[vbcode.io] 为推荐的大模型 API 服务提供方之一。


## APP 截图
<table>
  <tr>
    <td width="50%"><img width="100%" alt="首页截图" src="https://github.com/user-attachments/assets/e2e6fdd6-4ed8-42c9-b69c-57eaa30d2faa" /></td>
    <td width="50%"><img width="100%" alt="AI 服务配置截图" src="https://github.com/user-attachments/assets/6c4b6d0d-5d11-4d08-86eb-969013aa18c2" /></td>
  </tr>
  <tr>
    <td width="50%"><img width="100%" alt="错题分析截图" src="https://github.com/user-attachments/assets/68a6c5ce-32dc-428d-af4f-b48f98d5eafc" /></td>
    <td width="50%"><img width="100%" alt="练习复习截图" src="https://github.com/user-attachments/assets/3f31dd6d-cd96-4bcf-934a-e183b937b0f5" /></td>
  </tr>
</table>

## Star History

<a href="https://www.star-history.com/?repos=tjunsh%2Fai-wrong-notebook&type=date&legend=bottom-right">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=tjunsh/ai-wrong-notebook&type=date&theme=dark&legend=bottom-right&sealed_token=2lVYUUSKE8Xg32kBXKLor7LPPEricQqczyw-61c4TjLwI8lSK_eOk3jD3MovEhuEyaOv9ZBIaBDZ4X0hXwNB2UXtGtPHBEm8mYBD6xHGCIS7kpQPTB8IP0WvStcKiTnEEVL1PdpOZruKI84VrOxGmXsb8LVwYgmLeP9E6x6kqj8WD6AI7fd2OBc2BAjW" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=tjunsh/ai-wrong-notebook&type=date&legend=bottom-right&sealed_token=2lVYUUSKE8Xg32kBXKLor7LPPEricQqczyw-61c4TjLwI8lSK_eOk3jD3MovEhuEyaOv9ZBIaBDZ4X0hXwNB2UXtGtPHBEm8mYBD6xHGCIS7kpQPTB8IP0WvStcKiTnEEVL1PdpOZruKI84VrOxGmXsb8LVwYgmLeP9E6x6kqj8WD6AI7fd2OBc2BAjW" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=tjunsh/ai-wrong-notebook&type=date&legend=bottom-right&sealed_token=2lVYUUSKE8Xg32kBXKLor7LPPEricQqczyw-61c4TjLwI8lSK_eOk3jD3MovEhuEyaOv9ZBIaBDZ4X0hXwNB2UXtGtPHBEm8mYBD6xHGCIS7kpQPTB8IP0WvStcKiTnEEVL1PdpOZruKI84VrOxGmXsb8LVwYgmLeP9E6x6kqj8WD6AI7fd2OBc2BAjW" />
 </picture>
</a>

## 欢迎大家赞赏和支持

### 请我买点 Token

AI错题本是我利用业余时间，一点点做起来的。

除了写代码，我也会拿真实题目反复测试，看看题目有没有读错、解析能不能讲明白、追问有没有答到点上。

如果这个工具刚好帮到了你，欢迎请我买一点 Token，支持后续开发和测试。

这些支持会用于支付 AI 开发工具的 Token 费用，帮助我继续为大家开发新功能、优化已有功能、修复问题，让这个项目能够持续迭代。

金额随意，量力而行。

赞赏完全自愿，不影响软件使用，也不兑换解题额度或会员权益。

无论是否赞赏，你的使用、反馈和分享，同样是对项目的支持。

谢谢你陪伴 AI错题本继续成长。也欢迎继续带着真实题目和使用感受来找我。

### 微信赞赏

使用微信扫一扫，金额随意！

<a href="docs/assets/wechat-appreciation.jpg">
  <img src="docs/assets/wechat-appreciation.jpg" alt="AI错题本微信赞赏码：请我买点 Token" width="300" />
</a>

### 爱发电

也可以通过 [爱发电赞赏](https://afdian.com/a/tjunsh) 支持本项目。

## License

MIT
