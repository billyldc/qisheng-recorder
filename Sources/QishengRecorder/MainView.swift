import SwiftUI
import AppKit
import ReplayCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var tab = "setup"
    @State private var editingReview: ReviewSelection?
    init(model: AppModel, initialTab: String = "setup") {
        self.model = model
        _tab = State(initialValue: initialTab)
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $tab) {
                Label("首次设置", systemImage: "checkmark.shield").tag("setup")
                Label("录制对局", systemImage: "record.circle").tag("record")
                Label("已录视频", systemImage: "film.stack").tag("files")
                Label("角色库", systemImage: "photo.on.rectangle").tag("library")
                Label("运行日志", systemImage: "list.bullet.rectangle").tag("logs")
            }
            .navigationSplitViewColumnWidth(160)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("七圣召唤录制器").font(.headline)
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · macOS 15+").font(.caption).foregroundStyle(.secondary)
                    UpdateButton(model: model, updater: model.updater)
                }.padding()
            }
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch tab {
                    case "setup": setup
                    case "files": files
                    case "library": CharacterLibraryView(model: model)
                    case "logs": logs
                    default: recording
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 12) {
                    Circle().fill(model.recording ? Color.red : model.busy ? Color.orange : Color.green).frame(width: 7, height: 7)
                    Text(model.status).font(.callout).lineLimit(2)
                    Spacer()
                    if model.recording { Text(String(format: "%02d:%02d", model.elapsed / 60, model.elapsed % 60)).monospacedDigit() }
                    if model.busy || model.selectionActive {
                        Button(action: model.stop) { Label("停止", systemImage: "stop.fill") }.tint(.red)
                    }
                }.padding(14)
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("录制器", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("确定") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onAppear { if model.ready && tab == "setup" { tab = "record" } }
        .onChange(of: model.settings.targetBundleID) { _, _ in model.resetSelection(clearKeepAlive: true) }
        .sheet(item: $editingReview, onDismiss: { model.editingReviewVideo = nil }) { selection in
            VideoReviewEditor(video: selection.video, review: selection.review,
                              rerun: { model.queueReview(selection.video) },
                              saved: { model.reviewMessages[selection.video] = VideoReview.load(selection.video)?.summary })
        }
        .sheet(isPresented: $model.configuringCloudAccount) {
            CloudAccountEditor(saved: model.cloudAccountWasSaved)
        }
        .onChange(of: model.settings.captureMode) { _, mode in
            if mode == .region { model.settings.unattended = false }
            model.resetSelection()
        }
        .sheet(isPresented: $model.choosingWindow) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(model.choosingKeepAliveWindow ? "校准保活页面" : "选择游戏窗口").font(.title2.bold())
                    Spacer()
                    Button(action: model.cancelWindowChoice) { Image(systemName: "xmark") }.help("取消")
                }
                List(model.windowChoices) { window in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(window.title.isEmpty ? "未命名窗口" : window.title).lineLimit(2)
                            Text("\(Int(window.frame.width)) × \(Int(window.frame.height)) · 窗口 \(window.id)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.useWindow(window) } label: { Label("选择", systemImage: "checkmark") }
                    }.padding(.vertical, 5)
                }
                if model.choosingKeepAliveWindow {
                    controlNote("先在浏览器选中原神标签页，再选择对应窗口。重新打开应用、关闭该窗口或标签页后，需要重新校准。")
                }
            }.padding(20).frame(width: 650, height: 420)
                .onDisappear { model.cancelWindowChoice() }
        }
    }

    private var setup: some View {
        Form {
            Section("权限") {
                permissionRow("屏幕与系统音频录制", subtitle: "录下选框中的游戏画面和电脑声音", granted: model.screenAllowed, action: model.requestScreenPermission)
                permissionRow("辅助功能", subtitle: "点击回放、二倍速与退出观看按钮", granted: model.accessibilityAllowed, action: model.requestAccessibility)
                HStack {
                    Text("授权在系统设置中完成；系统要求重新打开时，退出并重新打开此应用。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(action: model.refreshPermissions) { Label("重新检测", systemImage: "arrow.clockwise") }
                }
            }
            Section("云原神账号") {
                HStack {
                    Label(model.cloudAccountSaved ? "已保存到本机钥匙串" : "尚未配置账号", systemImage: "key.fill")
                    Spacer()
                    Button { model.configuringCloudAccount = true } label: {
                        Label(model.cloudAccountSaved ? "修改账号" : "配置账号密码", systemImage: "person.crop.circle.badge.plus")
                    }
                    if model.cloudAccountSaved {
                        Button(role: .destructive, action: model.removeCloudAccount) { Image(systemName: "trash") }.help("移除已保存账号")
                    }
                    if model.canUndoCloudAccountRemoval {
                        Button(action: model.undoCloudAccountRemoval) { Label("撤回", systemImage: "arrow.uturn.backward") }
                    }
                }
                Toggle("使用已保存账号自动登录", isOn: $model.settings.cloudAutoLogin).disabled(!model.cloudAccountSaved)
                controlNote("先切换到密码登录，再逐字模拟键盘输入并尝试登录一次。输入期间请勿切换窗口或操作键盘；遇到验证码会暂停。密码不经过剪贴板，不写入配置文件或日志。")
                controlNote("成功读取后仅在本次解锁会话内复用账号，不会每次点击都访问钥匙串。锁屏、锁定钥匙串、切换用户、休眠或退出时清除内存副本。")
                controlNote("若 macOS 询问钥匙串访问，请输入该钥匙串密码并选「始终允许」；仅点「允许」不代表永久授权。更新或钥匙串重新锁定后，系统仍可能再次确认。")
                Toggle("同意官方协议，并在登录时自动勾选", isOn: $model.settings.cloudAutoAcceptAgreements)
                controlNote("开启表示你同意《米哈游用户协议》《米哈游隐私政策》，并授权本应用在后续密码登录时自动勾选。可随时关闭，关闭后需手动确认；不勾选其他授权。")
                HStack(spacing: 16) {
                    Link("查看用户协议", destination: SafariLauncher.userAgreementURL)
                    Link("查看隐私政策", destination: SafariLauncher.privacyAgreementURL)
                }.font(.callout)
            }
            Section("录制配置") {
                Picker("目标应用", selection: $model.settings.targetBundleID) {
                    Text("Google Chrome · 云原神").tag("com.google.Chrome")
                    Text("Safari · 云原神").tag("com.apple.Safari")
                    ForEach(NSWorkspace.shared.runningApplications.filter {
                        $0.activationPolicy == .regular && $0.bundleIdentifier != "com.google.Chrome" && $0.bundleIdentifier != "com.apple.Safari" && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                    }, id: \.processIdentifier) { app in
                        if let id = app.bundleIdentifier { Text(app.localizedName ?? id).tag(id) }
                    }
                }
                Toggle("录制系统声音", isOn: $model.settings.systemAudio)
                HStack {
                    Text(model.assetStatus).font(.callout)
                    Spacer()
                    Button { tab = "library" } label: { Label("浏览图片", systemImage: "photo.on.rectangle") }
                    Button(action: model.updateAssets) { Label("更新角色库", systemImage: "arrow.down.circle") }
                        .disabled(model.reviewingVideo != nil)
                        .help("从 Yatta 的公开七圣召唤目录增量下载新角色参考图；已有参考图保留，识别仍在本机完成。")
                }
                Text(model.assetDetails).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Toggle("每天自动检查角色库更新", isOn: $model.settings.autoAssetUpdates)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("录完后后台多帧复核", isOn: $model.settings.autoReview)
                    controlNote("整批录完后核对角色；不延长保活，不改原视频或文件名。")
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text("视频保存位置")
                        Text(model.settings.outputDirectory).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button(action: model.chooseDirectory) { Label("选择", systemImage: "folder") }
                }
            }
            Section {
                Button { tab = "record" } label: { Label("进入录制", systemImage: "arrow.right") }.disabled(!model.screenAllowed)
            }
        }.formStyle(.grouped).disabled(model.busy || model.selectionActive).navigationTitle("首次设置")
    }

    private func permissionRow(_ title: String, subtitle: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle").font(.title2).foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            Spacer()
            Button(granted ? "已授权" : "开启权限", action: action).disabled(granted)
        }.padding(.vertical, 8)
    }

    private var recording: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("录制对局").font(.title2.bold())
                    Spacer()
                    Button {
                        model.choosingKeepAliveWindow = false
                        if model.settings.captureMode == .window { model.chooseWindow() } else { model.selectRegion() }
                    } label: {
                        Label(model.settings.captureMode == .window ? "选择窗口" : "选择区域", systemImage: model.settings.captureMode == .window ? "macwindow" : "viewfinder")
                    }
                    Button(action: model.scan) { Label("重新识别", systemImage: "arrow.clockwise") }.disabled(model.region == nil)
                    Button(action: model.testRecording) { Label("试录 10 秒", systemImage: "waveform") }.disabled(model.region == nil || !model.screenAllowed)
                }.disabled(model.busy || model.selectionActive)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("双方视角录制", isOn: $model.settings.bothPerspectives)
                        .toggleStyle(.checkbox)
                        .disabled(model.busy || model.selectionActive)
                    controlNote(model.settings.bothPerspectives
                                ? "先录全部已选对局的己方视角，再录全部对方视角（己方 1–n → 对方 1–n）；共 \(model.selectedRows.count * 2) 段。每局单独选择暂不生效，关闭后恢复。"
                                : "关闭时按每局选择的视角录一次；开启后录两轮，录完第二轮才停止本批保活。")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("一键启动默认视角")
                        Picker("一键启动默认视角", selection: $model.settings.autoStartPerspective) {
                            ForEach(ReplayPerspective.allCases, id: \.self) { perspective in
                                Text(perspective.label).tag(perspective)
                            }
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 200)
                            .disabled(model.settings.bothPerspectives || model.busy || model.selectionActive)
                    }
                    controlNote(model.settings.bothPerspectives
                                ? "双方视角录制已开启，此设置暂不生效。"
                                : "仅用于一键启动后新识别的对局；下方开始录制仍保留每局手动选择。")
                    HStack {
                        Button(action: model.launchSafariAndRecord) {
                            Label(model.cloudLaunchPhase.needsUser ? "继续检查并录制" : "启动 Safari 并录制", systemImage: "safari")
                        }.disabled(!model.ready || model.busy || model.selectionActive || model.editingReviewVideo != nil)
                        if model.cloudLaunchPhase == .login { Label("等待登录或验证码", systemImage: "person.badge.key").foregroundStyle(.orange) }
                        else if model.cloudLaunchPhase == .needsFavorites { Label("需要进入收藏列表", systemImage: "hand.raised").foregroundStyle(.orange) }
                    }
                    controlNote("Safari 的“开始录制”会先登录并启动游戏；游戏画面可识别时尝试通过地图前往猫尾酒馆，再与小王子对话并切到收藏。无法确认地图或遇到验证码时会停止并提示。自动密码登录和协议设置分别开启；本批导航和录制期间保活，结束或停止时关闭。上方入口录当前页全部对局，下方保留已勾选对局和人工角色修正，不翻页。")
                }
                Picker("录制范围", selection: $model.settings.captureMode) {
                    Label("手动选框", systemImage: "viewfinder").tag(CaptureMode.region)
                    Label("全窗口", systemImage: "macwindow").tag(CaptureMode.window)
                }.pickerStyle(.segmented).frame(maxWidth: 460).disabled(model.busy || model.selectionActive)
                    .help("全窗口会识别官方云原神内容区并裁去多帧一致的黑边；每局录完导出，完整原片保留在「原始窗口」子目录。无法确认时保留边缘或提示手动选框。")
                if model.settings.captureMode == .region {
                    Picker("选框显示器", selection: $model.settings.captureDisplayID) {
                    Text("跟随游戏窗口").tag(Optional<UInt32>.none)
                    ForEach(model.displays, id: \.id) { display in
                        Text(display.label).tag(Optional(display.id))
                    }
                }.frame(maxWidth: 460, alignment: .leading).disabled(model.busy || model.selectionActive)
                }
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("无人值守", isOn: $model.settings.unattended).disabled(model.settings.captureMode != .window)
                        .help("仅适用于全窗口。失焦时继续捕获，点击或保活前恢复所选窗口。远程断开不能伴随锁屏或注销；真实锁屏仍会停止并保存。")
                        controlNote("防休眠在录制电脑上生效；锁屏、注销或合盖仍会停止。")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("悬浮日志与停止按钮", isOn: $model.settings.showHUD)
                        .help("悬浮窗不进入录像，可拖动位置。关闭后仍可通过菜单栏或 Cmd+Shift+S 停止。")
                        controlNote("不进入录像；关闭主窗口不会停止录制。")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.toggleStyle(.checkbox).disabled(model.busy || model.selectionActive)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Button(action: model.chooseKeepAliveWindow) { Label("校准保活页面", systemImage: "scope") }
                            .disabled(model.busy || model.selectionActive)
                            .help("先在目标窗口选中原神标签页，再选择该窗口。只记住窗口和标签页，不识别对局、不录制。")
                        Text(model.keepAliveTarget?.label ?? "尚未校准保活页面").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if model.keepAliveOnly {
                            Text("已保活 \(model.keepAliveCount) 次").monospacedDigit()
                            Button(action: model.stop) { Label("停止保活", systemImage: "stop.fill") }.tint(.red).disabled(model.stopping)
                        } else {
                            Button(action: model.startKeepAlive) { Label("只保活", systemImage: "cursorarrow.motionlines") }
                                .disabled(!model.canKeepAlive)
                                .help("按保活间隔恢复游戏窗口并移动鼠标，不点击、不录制。若只能绑定当前页面，切换标签或刷新会停止；锁屏后停止。")
                        }
                    }
                    controlNote(model.keepAliveAvailabilityNote)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 20) {
                        Toggle("录制期间保活", isOn: $model.settings.cloudKeepAlive)
                            .help("回放录制期间定时移动鼠标，不点击、不按键；停止或录制结束后关闭。与防系统休眠相互独立。")
                        if model.settings.cloudKeepAlive || model.keepAliveTarget != nil {
                            Stepper("每 \(model.settings.keepAliveSeconds, specifier: "%.0f") 秒", value: $model.settings.keepAliveSeconds,
                                    in: KeepAliveSchedule.allowedInterval, step: 15)
                                .frame(width: 160)
                                .help("间隔可设为 15–120 秒，默认沿用旧脚本的 60 秒。")
                        }
                        Spacer()
                    }.toggleStyle(.checkbox).disabled(model.busy || model.selectionActive)
                    controlNote("录完或中途停止即结束保活，不会自动转为「只保活」。此开关不影响单独开启的「只保活」。")
                }
                HStack(alignment: .top, spacing: 20) {
                    Group {
                        if let image = model.preview {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            ContentUnavailableView("尚未选取画面", systemImage: "viewfinder")
                        }
                    }.frame(maxWidth: .infinity).frame(height: 220).background(Color.black.opacity(0.045))
                    VStack(alignment: .leading, spacing: 13) {
                        if let region = model.region {
                            Text(model.displays.first { $0.id == region.displayID }?.label ?? "显示器已断开")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text("\(Int(region.sourceRect.width)) × \(Int(region.sourceRect.height)) 点").monospacedDigit()
                        }
                        Toggle("自动点击二倍速", isOn: $model.settings.speed2x)
                        controlNote("录制期间复核倍速；多次未成功时继续录制，并在运行日志提示核对。")
                        Label(model.calibration.speed == nil ? "二倍速：自动识别" : "二倍速：手动校准优先", systemImage: "scope")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { model.calibrate("speed") } label: {
                            Label("校准二倍速（可选）", systemImage: "scope")
                        }.disabled(model.region == nil).help("先手动进入回放，等控件出现后校准。校准仅选取坐标，不会点击游戏。完成后返回收藏列表。")
                        Label(model.calibration.exit == nil ? "退出观看：自动识别" : "退出观看：自动识别 + 备用坐标", systemImage: "scope")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { model.calibrate("exit") } label: { Label("校准退出观看（可选）", systemImage: "scope") }
                            .disabled(model.region == nil).help("在对局结束画面选取退出观看按钮。仅当已确认对局结束但自动定位失败时使用，不会提前退出。")
                        HStack {
                            Text("加载等待")
                            TextField("秒", value: $model.settings.loadingSeconds, format: .number).frame(width: 44)
                            Text("秒").foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("单局上限")
                            TextField("秒", value: $model.settings.maxSeconds, format: .number).frame(width: 54)
                            Text("秒").foregroundStyle(.secondary)
                        }
                    }.frame(width: 230).disabled(model.busy || model.selectionActive)
                }
                Divider()
                HStack {
                    Text("收藏对局").font(.headline)
                    Text("\(model.selectedRows.count) 局已选").foregroundStyle(.secondary)
                    Spacer()
                    Button(action: model.addManualRow) { Label("添加", systemImage: "plus") }.disabled(model.busy)
                }
                ForEach($model.rows) { $row in
                    ReplayRow(row: $row, active: model.activeRow == row.id, bothPerspectives: model.settings.bothPerspectives) { model.calibrate("play", rowID: row.id) }
                        .disabled(model.busy || model.selectionActive)
                }
                HStack {
                    controlNote(model.settings.cloudKeepAlive
                                ? "本批录完后停止保活；需要继续在线，请另开「只保活」。"
                                : "本批录制保活已关闭；长时间无操作可能掉线。")
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button(action: model.beginRecording) { Label("开始录制", systemImage: "record.circle") }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.large).disabled(!model.canBeginRecording)
                }
            }.padding(22)
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("已录视频").font(.title2.bold())
                Spacer()
                if model.reviewingVideo != nil {
                    Button { Metadata.cancelReview() } label: { Label("取消当前复核", systemImage: "stop.fill") }
                }
                Button(action: model.importReviewVideos) { Label("导入录像复核", systemImage: "plus") }
                Button(action: model.openOutput) { Label("打开目录", systemImage: "folder") }
            }
            controlNote("复核只检查角色，不改原视频或文件名，也不会保活；人工确认的角色不会被自动覆盖。")
            if !model.reviewVideos.isEmpty {
                List(model.reviewVideos, id: \.self) { video in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(video.lastPathComponent).lineLimit(2)
                            Text(model.reviewMessages[video] ?? "等待复核").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.queueReview(video) } label: { Image(systemName: "arrow.clockwise") }
                            .help("重新抽帧复核").disabled(model.reviewingVideo == video || model.reviewQueue.contains(video))
                        Button {
                            if let review = VideoReview.load(video) {
                                model.editingReviewVideo = video
                                editingReview = ReviewSelection(video: video, review: review)
                            }
                        } label: { Image(systemName: "pencil") }.help("核对证据与人工纠错")
                            .disabled(model.reviewingVideo == video || model.reviewQueue.contains(video) || VideoReview.load(video) == nil)
                    }
                }.frame(minHeight: 160)
            }
            if model.entries.isEmpty { ContentUnavailableView("本次尚无录像", systemImage: "film.stack").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                List(model.entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) { Text(entry.url.lastPathComponent).lineLimit(2); Text(entry.detail).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button { NSWorkspace.shared.open(entry.url) } label: { Image(systemName: "play.fill") }.help("播放视频")
                        Button { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } label: { Image(systemName: "folder") }.help("在 Finder 中显示")
                    }.padding(.vertical, 6)
                }
            }
        }.padding(22)
    }
    private func controlNote(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var logs: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("运行日志").font(.title2.bold())
            ScrollView { Text(model.log.joined(separator: "\n")).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(22)
    }
}

private struct UpdateButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Button {
            guard !model.busy && !model.selectionActive && model.reviewingVideo == nil else { return }
            model.busy = true
            Task {
                defer { model.busy = false }
                await updater.checkAndOffer()
            }
        } label: { Label(updater.working ? "正在更新…" : "检查更新", systemImage: "arrow.down.circle") }
            .disabled(model.busy || model.selectionActive || updater.working || model.reviewingVideo != nil)
            .help("通过本机 GitHub CLI 登录访问私有仓库，检查、下载并安装更新。录制或保活时不可更新。")
    }
}

private struct ReplayRow: View {
    @Binding var row: Replay
    var active: Bool
    var bothPerspectives: Bool
    var calibrate: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("第 \(row.id) 局", isOn: $row.selected).toggleStyle(.checkbox).font(.headline)
                TextField("日期时间", text: $row.date).frame(width: 160)
                TextField("模式", text: $row.mode).frame(width: 112)
                Spacer()
                Button(action: calibrate) { Image(systemName: "scope") }.help("校准本局播放按钮")
            }
            HStack(spacing: 10) {
                Picker("录制视角", selection: Binding(get: { row.preferredPerspective }, set: { row.recordingPerspective = $0 })) {
                    ForEach(ReplayPerspective.allCases, id: \.self) { view in Text(view.label).tag(view) }
                }.pickerStyle(.segmented).frame(width: 280).disabled(bothPerspectives)
                if bothPerspectives {
                    Text("己方不检查菜单；对方持续等待切换，开头可能含等待时的己方画面").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(row.preferredPerspective == .opponent ? "掷骰后先暂停，再切换并继续播放；暂不可切换会恢复播放后重试，开头可能仍是己方" : "默认己方视角，不暂停、不检查切换菜单").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Text("己方").foregroundStyle(.secondary)
                ForEach(0..<3) { index in TextField("角色", text: teamBinding(left: true, index: index), axis: .vertical).lineLimit(2).frame(minHeight: 34) }
                Text("对方").foregroundStyle(.secondary)
                ForEach(0..<3) { index in TextField("角色", text: teamBinding(left: false, index: index), axis: .vertical).lineLimit(2).frame(minHeight: 34) }
            }
        }.padding(12).background(active ? Color.red.opacity(0.08) : Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }
    private func teamBinding(left: Bool, index: Int) -> Binding<String> {
        Binding(get: { let team = left ? row.left : row.right; return team.indices.contains(index) ? team[index] : "未识别" }, set: { value in
            if left { while row.left.count < 3 { row.left.append("未识别") }; row.left[index] = value }
            else { while row.right.count < 3 { row.right.append("未识别") }; row.right[index] = value }
            var confirmed = row.manualCharacters ?? Array(repeating: false, count: 6)
            while confirmed.count < 6 { confirmed.append(false) }
            confirmed[(left ? 0 : 3) + index] = true
            row.manualCharacters = confirmed
        })
    }
}

private struct ReviewSelection: Identifiable {
    let id = UUID()
    var video: URL
    var review: VideoReview
}
