# hi建大 · Android 客户端（Flutter）

> 仅供个人账号的正当学习用途。只读访问教务系统，低频请求。
> 应用不保存密码（除非你主动勾选「记住账号密码」，且存入系统密钥库）。
> 本项目完全是 vibecode，无任何人工审查，请不要妄图人工审查代码折磨自己，
> 未来也大概率不会做功能性更新。

---

## 功能

| 模块 | 状态 | 说明 |
|---|---|---|
| 登录（图形验证码） | 完成 | 本机 ONNX 推理识别（实测 ≈92%）；可记住账号密码（系统密钥库） |
| 课表 | 完成 | 整周固定一屏（7 天 × 5 节）；本地缓存 + **增删改**；周次/单双周过滤 |
| 成绩 | 完成 | 学期筛选 + 搜索 + 客户端汇总（总学分 / 平均绩点） |
| 培养方案 | 完成 | 课程设置总表（按课程体系分级，可折叠）+ **PDF 附件下载** |
| 通选课修读情况 | 完成 | **大类 → 具体课程**（可折叠）；类别进度 |
| 空教室查询 | 完成 | 按校区/楼栋/节次查；客户端做周次与节次过滤 |
| 个人信息 | 完成 | 学籍信息分组展示 |
| 桌面卡片 | 完成 | Android App Widget，按时间高亮下一节课；课表改动自动同步 |
| 上课提醒 | 完成 | 本地通知，系统托管，应用关闭仍触发 |
| 校历与作息 | 完成 | 校历来自教务系统教学周历（随学年更新），作息表来自课表页；**校历网址由用户填写** |
| 界面材质 | 完成 | 液态玻璃 / Material 3 两套，设置里可切换 |

---

## 工程结构

```
lib/
├── main.dart                     入口；生命周期钩子
├── common/                       constants / result(AppError) / week_calc / url_guard
├── crypto/qz_encoder.dart        登录编码（Base64）
├── network/                      cookie_jar / http_client / qz_api
├── parser/                       html_lite + 7 个页面解析器
│                                 (timetable / score / profile / plan / elective /
│                                  classroom / week_calendar)
├── model/                        models / classroom_models / reminder_plan
│                                 captcha_charset / card_layout(卡片尺寸规划)
├── data/                         pref_store / credential_store / session_cookie_store
│                                 timetable_store / app_state / week_service
│                                 section_time_store / reminder_service
│                                 card_snapshot_store / captcha_model / captcha_solver
│                                 re_auth_service / avatar_store / pdf_store / pdf_saver
│                                 elective_requirement_store / page_cache(三层缓存)
│                                 academic_calendar / campus_calendar_service
│                                 semester_calendar_service
├── theme/                        theme.dart / glass_kit.dart / material_style.dart
├── widgets/                      state_views / app_refresh / course_editor
│                                 reauth_dialog / credentials_box / glass_picker
│                                 glass_picker_field / calendar_sheet
│                                 semester_month_grid / section_time_dialog
│                                 requirement_editor_dialog / avatar_crop_dialog
│                                 top_fade_blur
└── pages/                        shell + login / schedule / score / plan / elective /
                                  classroom / profile / settings + top_bar_slot
shaders/top_fade_blur.frag        顶部渐变模糊着色器
test/                             354 个用例（解析器 / 缓存 / 布局 / 提醒 / UI …）
test/fixtures/                    人工脱敏过的真实页面语料
android/app/src/main/
├── AndroidManifest.xml
├── kotlin/.../MainActivity.kt
├── kotlin/.../TodayCourseWidgetProvider.kt     桌面卡片
└── res/layout/today_course_widget.xml
android/app/src/debug/jniLibs/x86_64/           模拟器专用的 ONNX 运行库
docs/技术笔记.md                  实现细节、排查记录、已知限制
tools/                            图标生成、脱敏、开源前审计脚本
```

---

## 构建与运行

### 环境

- Flutter 3.44.2（Dart 3.12）
- Android SDK：compileSdk **36**、minSdk 24、targetSdk 36
- **JDK 17**

### 构建

```bash
flutter pub get
flutter build apk --debug      # 或 --release
```

产物：`build/app/outputs/flutter-apk/app-debug.apk`
（含 arm64-v8a / armeabi-v7a / x86_64 三个 ABI）

### 运行

```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.sdjzu.hijianzhu/.MainActivity
```

### 测试

```bash
flutter test
```

### 开源前自检

```bash
python tools/check_ignore.py       # 复核 .gitignore 是否挡住敏感路径
python tools/scan_publishable.py   # 扫描「会入库的文件」里有无真实 PII
python tools/audit_sensitive.py .  # 模式匹配扫源码
python tools/audit_sensitive.py app-release.apk   # 扫最终产物
```

实现细节、构建环境的坑、排查记录与已知限制，见 [docs/技术笔记.md](docs/技术笔记.md)。

---

## 开源致谢

按类别列出；括号内为许可协议。

- **UI 与视觉**：liquid_glass_widgets (MIT)、cupertino_icons (MIT)
- **数据与存储**：shared_preferences (BSD-3)、flutter_secure_storage (BSD-3)、
  path_provider (BSD-3)、image_picker (Apache-2.0)、home_widget (BSD-3)
- **通知与提醒**：flutter_local_notifications (BSD-3)、timezone (BSD-2)
- **验证码识别**：ddddocr (MIT) —— `assets/captcha.onnx` 来自其发行包，
  二次分发请保留其许可声明；onnxruntime (MIT)、image (MIT)
- **网络与工具**：http (BSD-3)、flutter_lints (BSD-3)
- **框架**：Flutter / Dart (BSD-3)

---

## 非代码来源

- **作息时刻**：取自教务系统**课表页**——节次行的首格自带起止时刻
  （`第一大节 (01,02小节) 07:50-09:25`）。教务处官网只发校历 PDF，
  没有独立的作息页。
- **校历**：主体数据来自教务系统的**教学周历**（可随学年自动更新）；
  官网那份校历图仅作佐证。**网址由用户自己填写** —— 这个页面的地址
  逐年在变，写死一个必然过期，而过期的校历比没有更糟。
- **应用图标与校徽**：本人手绘。

## 本项目自身

以 MIT 许可开源，见 [LICENSE](LICENSE)。

由同作者的鸿蒙版（ArkTS）移植而来；鸿蒙版尚未开源。

## 隐私

- 只访问**你自己**的账号，只做只读查询，请求频率与手动刷网页相当。
- 除教务系统与学校官网外，**不向任何第三方发送数据**；验证码识别在
  本机完成（不调用云服务）。
- 密码默认不保存。勾选「记住账号密码」后存入系统密钥库
  （Android Keystore），取消勾选或退出登录即清除。
- 本地缓存（课表 / 成绩 / 培养方案）只存在设备上，按账号分片。

**免责声明**：本项目为个人学习用途的第三方客户端，与山东建筑大学无隶属关系，
仅供查询本人教务数据。请遵守学校相关规定，不要用于批量抓取或任何非本人用途。
