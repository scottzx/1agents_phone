# Flavor / Role Pack 装配契约（v0.3）

总架构（存储、根体验、并行边界）见 [../architecture.md](../architecture.md)。本文只约定装配字段与工程接线。

## 目标

- **多 Target 白标**：同一套完整 Runtime + App Shell，多个垂直 App。
- **不裁剪能力**：垂直 App 与 Minis 同源源码；差异在默认 Pack 与入口。
- **iOS 为权威源**：待办 / 日历 / 客户等写穿系统；Pack 不造平行业务库。
- **iSH + Skill 为扩展主通道**。

## 目录

```
src/ios/
  FlavorKit/                 # 装配运行时
    FlavorConfig.swift
    FlavorRootView.swift     # 按 root_experience 选根页
    RolePackInstaller.swift
    RolePackManifest.swift
  Flavors/
    openminis/               # 默认 Minis Target
      FlavorConfig.json
      RolePack/
    sales/
    english/
    fitness/
  Scenes/
    sales/SalesHomeView.swift
  scripts/
    embed_role_pack.sh       # 构建期按 FLAVOR_ID 拷入 Bundle
    add_flavor_targets.py    # 工程装配 / 克隆 Target
```

## Targets

| Target | Bundle ID | FLAVOR_ID | 说明 |
|--------|-----------|-----------|------|
| Minis | com.1agents.phone | openminis | 主产品；含 Extensions；`standard_chat` |
| MinisSales | com.1agents.phone.sales | sales | 垂直包；`scene_home` → `SalesHomeView` |
| MinisEnglish | com.1agents.phone.english | english | 垂直包；`chat_with_rail`（UI 暂回退会话列表） |
| MinisFitness | com.1agents.phone.fitness | fitness | 垂直包；`chat_with_rail`（UI 暂回退会话列表） |

垂直 Target **暂不**嵌入 Share / Widget / FileProvider（宿主 Bundle ID 前缀限制）。需要时再为各 flavor 克隆扩展。

工程实现：

- 四个 App Target **共享**同一套 Sources / Resources / Frameworks build phase（不复制源码列表）。
- 差异仅在 Target Build Settings：`FLAVOR_ID`、`PRODUCT_BUNDLE_IDENTIFIER`、`INFOPLIST_KEY_CFBundleDisplayName`。
- 垂直 Target 暂复用 `Minis.entitlements`（同 App Group / iCloud）；同机多装时 **App Group 数据共享**，**App 本体与 `Documents/alpine-rootfs` 按包复制**。后续若要隔离再拆容器。

## 构建

1. 设置 `FLAVOR_ID`（各 Target Build Settings）。
2. Run Script **Embed Role Pack** → `scripts/embed_role_pack.sh`  
   将 `Flavors/$FLAVOR_ID/FlavorConfig.json` 与 `RolePack/` 拷入 app resources。
3. 启动时 `RolePackInstaller.installIfNeeded()`（在 `SoulStore.ensureExists()` 之前）。

重新生成 / 同步 Target：

```bash
python3 src/ios/scripts/add_flavor_targets.py
```

## FlavorConfig.json

见 `FlavorKit/FlavorConfig.swift`。关键字段：`flavor_id`、`pack`、`root_experience`、`defaults`。

## RolePack/manifest.json

见 `FlavorKit/RolePackManifest.swift`。空壳阶段：

- `soul`：`first_launch_only` 写入 SOUL.md（若尚不存在）
- `skills`：可为空（后续 bundled 安装）
- `quick_actions_path`：加载到 `RolePackRuntime.shared.quickActions`。销售首页已展示；**尚未**预填到新会话。
- `system_bindings`：声明 iOS SSOT，不自动建库

## 并行开发边界

| 改哪里 | 谁改 |
|--------|------|
| `Platform` 现有源码 | 平台；四 App 共享 |
| `Flavors/<id>/` | 对应垂类队 |
| `FlavorKit/` | 平台（装配契约） |
| 新 Scene UI | `Scenes/<id>/`（源码进共享 phase，展示由 `FlavorRootView` 按 flavor 开关） |

## 后续

- `chat_with_rail` / quick_actions 挂会话预填
- Pack skills → SkillStore.bundled 安装
- 英语 / 健身 Scene 页；销售页从静态演示接到真实投影（提醒/日历/客户）
- 垂直扩展 Bundle ID + 独立 App Group（若需隔离数据）
