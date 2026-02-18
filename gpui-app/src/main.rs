use std::{
    io::{BufRead, BufReader, Write},
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::mpsc::{self, Receiver, Sender},
    thread,
    time::Duration,
};

use anyhow::{anyhow, Context, Result};
use global_hotkey::{
    hotkey::{Code, HotKey, Modifiers},
    GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState,
};
use gpui::{
    div, img, prelude::*, px, rgb, rgba, size, App, Application, AssetSource, Bounds,
    Context as GpuiContext, FocusHandle, Focusable, IntoElement, SharedString, Window,
    WindowBounds, WindowOptions,
};
use serde::Deserialize;

#[cfg(target_os = "macos")]
use {
    cocoa::appkit::NSWindowCollectionBehavior,
    objc::{msg_send, sel, sel_impl},
};

#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "type")]
#[allow(dead_code)]
enum BackendMessage {
    #[serde(rename = "entries")]
    Entries { data: Vec<Entry> },
    #[serde(rename = "select-success")]
    SelectSuccess { index: usize },
    #[serde(rename = "remove-success")]
    RemoveSuccess { index: usize },
    #[serde(rename = "success")]
    Success { message: String },
    #[serde(rename = "ready")]
    Ready,
    #[serde(other)]
    Unknown,
}

#[derive(Clone, Debug, Deserialize)]
struct Entry {
    id: usize,
    content: String,
    timestamp: i64,
    #[serde(default)]
    #[serde(rename = "type")]
    entry_type: EntryType,
    #[serde(default)]
    #[serde(rename = "isCurrent")]
    is_current: bool,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum EntryType {
    Text,
    Image,
    File,
}

impl Default for EntryType {
    fn default() -> Self {
        EntryType::Text
    }
}

#[derive(Debug, thiserror::Error)]
enum BackendError {
    #[error("failed to send command")]
    SendFailed,
}

struct BackendHandle {
    child: Option<Child>,
    tx: Sender<String>,
    rx: Receiver<BackendMessage>,
}

impl BackendHandle {
    fn start() -> Result<Self> {
        let path = discover_backend_binary()?;

        let mut child = Command::new(path)
            .args(["--json-api", "--low-power"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .context("failed to start clipz backend")?;

        let stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?;
        let stdout = child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?;

        let (cmd_tx, cmd_rx) = mpsc::channel::<String>();
        let (msg_tx, msg_rx) = mpsc::channel::<BackendMessage>();

        thread::spawn(move || pump_commands(stdin, cmd_rx));
        thread::spawn(move || pump_messages(stdout, msg_tx));

        Ok(Self {
            child: Some(child),
            tx: cmd_tx,
            rx: msg_rx,
        })
    }

    fn send(&self, command: impl Into<String>) -> Result<()> {
        self.tx
            .send(command.into())
            .map_err(|_| BackendError::SendFailed.into())
    }
}

impl Drop for BackendHandle {
    fn drop(&mut self) {
        let _ = self.tx.send("quit".into());
        if let Some(mut child) = self.child.take() {
            thread::sleep(Duration::from_millis(100));
            let _ = child.kill();
            let _ = child.wait();
        }
        std::process::exit(0);
    }
}

fn pump_commands(mut stdin: impl Write + Send + 'static, rx: Receiver<String>) {
    for command in rx {
        if let Err(e) = writeln!(stdin, "{}", command) {
            eprintln!("Failed to write command to backend: {}", e);
            break;
        }
        if let Err(e) = stdin.flush() {
            eprintln!("Failed to flush stdin: {}", e);
            break;
        }
    }
}

fn pump_messages(stdout: impl std::io::Read + Send + 'static, tx: Sender<BackendMessage>) {
    let reader = BufReader::new(stdout);
    for line in reader.lines() {
        match line {
            Ok(line) => {
                if let Ok(msg) = serde_json::from_str::<BackendMessage>(&line) {
                    if tx.send(msg).is_err() {
                        break;
                    }
                }
            }
            Err(e) => {
                eprintln!("Failed to read line from backend: {}", e);
                break;
            }
        }
    }
}

struct FileSystemAssets;

impl AssetSource for FileSystemAssets {
    fn load(&self, path: &str) -> Result<Option<std::borrow::Cow<'static, [u8]>>> {
        std::fs::read(path)
            .map(|data| Some(std::borrow::Cow::Owned(data)))
            .map_err(|e| e.into())
    }

    fn list(&self, _path: &str) -> Result<Vec<SharedString>> {
        Ok(Vec::new())
    }
}

const CURRENT_ENTRY_ID: usize = 1;

fn discover_backend_binary() -> Result<PathBuf> {
    let cwd = std::env::current_dir()?;
    let dev_path = cwd.join("zig-out/bin/clipz");
    if dev_path.exists() {
        return Ok(dev_path);
    }
    let packaged = std::env::current_exe().ok().and_then(|exe| {
        exe.parent()
            .and_then(|p| p.parent())
            .map(|p| p.join("Resources/bin/clipz"))
    });
    if let Some(p) = packaged {
        if p.exists() {
            return Ok(p);
        }
    }
    Err(anyhow!("clipz backend not found"))
}

fn filename_from_path(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .and_then(|f| f.to_str())
        .unwrap_or(path)
        .to_string()
}

const BG_BASE: u32 = 0x111111;
const BG_SURFACE: u32 = 0x1a1a1a;
const BG_HOVER: u32 = 0x222222;
const BG_ACTIVE: u32 = 0x1c2a3a;
const BORDER_SUBTLE: u32 = 0x2a2a2a;
const TEXT_PRIMARY: u32 = 0xf0f0f0;
const TEXT_SECONDARY: u32 = 0x999999;
const TEXT_MUTED: u32 = 0x555555;
const ACCENT_BLUE: u32 = 0x5ac8fa;
const ACCENT_ORANGE: u32 = 0xff9f0a;
const ACCENT_GREEN: u32 = 0x30d158;
const DANGER: u32 = 0xff453a;

struct ClipzApp {
    backend: Option<BackendHandle>,
    entries: Vec<Entry>,
    search: SharedString,
    focused_index: Option<usize>,
    focus_handle: FocusHandle,
    _hotkey_manager: GlobalHotKeyManager,
    hotkey_rx: Receiver<()>,
    scroll_position: f32,
}

impl Focusable for ClipzApp {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl ClipzApp {
    fn new(window: &mut Window, cx: &mut GpuiContext<Self>) -> Self {
        let focus_handle = cx.focus_handle();
        window.focus(&focus_handle);

        let hotkey_manager = GlobalHotKeyManager::new().expect("failed to create hotkey manager");
        let hotkey = HotKey::new(Some(Modifiers::SUPER | Modifiers::ALT), Code::Equal);
        hotkey_manager
            .register(hotkey)
            .expect("failed to register hotkey");

        let (hotkey_tx, hotkey_rx) = mpsc::channel::<()>();

        thread::spawn(move || {
            let receiver = GlobalHotKeyEvent::receiver();
            loop {
                if let Ok(event) = receiver.recv() {
                    if event.state == HotKeyState::Pressed {
                        let _ = hotkey_tx.send(());
                    }
                }
            }
        });

        cx.spawn(async move |this, cx| loop {
            cx.background_executor()
                .timer(Duration::from_millis(100))
                .await;
            let _ = this.update(cx, |app, cx| {
                while app.hotkey_rx.try_recv().is_ok() {
                    cx.activate(true);
                }
                cx.notify();
            });
        })
        .detach();

        let backend = BackendHandle::start().ok();
        let app = Self {
            backend,
            entries: Vec::new(),
            search: SharedString::from(""),
            focused_index: None,
            focus_handle,
            _hotkey_manager: hotkey_manager,
            hotkey_rx,
            scroll_position: 0.0,
        };

        if let Some(backend) = &app.backend {
            app.refresh_entries(backend);
        }

        app
    }

    fn poll_backend(&mut self) -> bool {
        let mut updated = false;
        if let Some(backend) = &self.backend {
            while let Ok(msg) = backend.rx.try_recv() {
                updated = true;
                match msg {
                    BackendMessage::Entries { data } => {
                        self.entries = data;
                        if let Some(idx) = self.focused_index {
                            let filtered = self.filtered();
                            if idx >= filtered.len() {
                                self.focused_index = if filtered.is_empty() {
                                    None
                                } else {
                                    Some(filtered.len() - 1)
                                };
                            }
                        }
                    }
                    BackendMessage::SelectSuccess { .. }
                    | BackendMessage::RemoveSuccess { .. }
                    | BackendMessage::Success { .. }
                    | BackendMessage::Ready => {
                        self.refresh_entries(backend);
                    }
                    BackendMessage::Unknown => {}
                }
            }
        }
        updated
    }

    fn filtered(&self) -> Vec<Entry> {
        if self.search.is_empty() {
            return self.entries.clone();
        }
        let query = self.search.to_lowercase();
        self.entries
            .iter()
            .filter(|e| e.content.to_lowercase().contains(&query))
            .cloned()
            .collect()
    }

    fn refresh_entries(&self, backend: &BackendHandle) {
        if let Err(e) = backend.send("get-entries") {
            eprintln!("Failed to refresh entries: {}", e);
        }
    }

    fn update_scroll_to_focused(&mut self) {
        if let Some(idx) = self.focused_index {
            const ENTRY_HEIGHT: f32 = 56.0;
            const VISIBLE_HEIGHT: f32 = 350.0;
            const CENTER_OFFSET: f32 = VISIBLE_HEIGHT / 2.0;

            let entry_top = idx as f32 * ENTRY_HEIGHT;

            self.scroll_position = (entry_top - CENTER_OFFSET).max(0.0);
        }
    }

    fn format_timestamp(&self, timestamp: i64) -> String {
        let now = match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
            Ok(duration) => duration.as_secs() as i64,
            Err(_) => return "unknown".to_string(),
        };
        let diff = now - (timestamp / 1000);

        if diff < 5 {
            "just now".to_string()
        } else if diff < 60 {
            format!("{}s ago", diff)
        } else if diff < 3600 {
            format!("{}m ago", diff / 60)
        } else if diff < 86400 {
            format!("{}h ago", diff / 3600)
        } else {
            format!("{}d ago", diff / 86400)
        }
    }

    fn select_entry(&mut self, id: usize, cx: &mut GpuiContext<Self>) {
        if let Some(backend) = &self.backend {
            for e in &mut self.entries {
                e.is_current = e.id == id;
            }
            if let Err(e) = backend.send(format!("select-entry:{id}")) {
                eprintln!("Failed to select entry: {}", e);
            }
            self.refresh_entries(backend);
        }
        cx.notify();
    }

    fn clear(&mut self, cx: &mut GpuiContext<Self>) {
        if let Some(backend) = &self.backend {
            if let Some(current) = self.entries.iter().find(|e| e.is_current).cloned() {
                self.entries = vec![current];
            } else {
                self.entries.clear();
            }
            if let Err(e) = backend.send("clear") {
                eprintln!("Failed to clear entries: {}", e);
            }
            self.refresh_entries(backend);
        }
        cx.notify();
    }

    fn remove(&mut self, id: usize, cx: &mut GpuiContext<Self>) {
        if let Some(backend) = &self.backend {
            self.entries.retain(|e| e.id != id);
            if let Err(e) = backend.send(format!("remove-entry:{id}")) {
                eprintln!("Failed to remove entry: {}", e);
            }
            self.refresh_entries(backend);
        }
        cx.notify();
    }

    fn render_entry(
        &self,
        entry: &Entry,
        idx: usize,
        focused_index: Option<usize>,
        view_entity: gpui::Entity<Self>,
    ) -> impl IntoElement + 'static {
        let id = entry.id;
        let content = entry.content.clone();
        let view = view_entity.clone();
        let view_remove = view_entity.clone();
        let entry_id_str = SharedString::from(format!("entry-{}", id));
        let is_current = entry.is_current;
        let is_focused = focused_index == Some(idx);
        let entry_type = entry.entry_type.clone();
        let image_path = entry.content.clone();
        let path_exists = std::path::Path::new(&image_path).exists();
        let timestamp_str = self.format_timestamp(entry.timestamp);

        let icon_color = match entry.entry_type {
            EntryType::Text => rgb(ACCENT_BLUE),
            EntryType::Image => rgb(ACCENT_ORANGE),
            EntryType::File => rgb(ACCENT_GREEN),
        };

        let type_label = match entry.entry_type {
            EntryType::Text => "Text",
            EntryType::Image => "Image",
            EntryType::File => "File",
        };

        let display_label: String = match entry_type {
            EntryType::Image | EntryType::File => {
                if path_exists {
                    filename_from_path(&content)
                } else {
                    content.clone()
                }
            }
            EntryType::Text => content.clone(),
        };

        let row_bg = if is_current {
            rgb(BG_ACTIVE)
        } else if is_focused {
            rgb(0x2a4a5a) // More visible blue highlight when focused
        } else {
            rgba(0x00000000)
        };

        div()
            .id(entry_id_str)
            .mx_2()
            .mb_1()
            .flex()
            .items_center()
            .gap_3()
            .px_3()
            .py(px(10.0))
            .bg(row_bg)
            .rounded_lg()
            .border_1()
            .border_color(if is_current {
                rgba(0x5ac8fa30)
            } else {
                rgba(0x00000000)
            })
            .hover(|style| style.bg(rgb(BG_HOVER)).border_color(rgb(BORDER_SUBTLE)))
            .cursor_pointer()
            .when(is_current, |el| {
                el.border_l_2().border_color(rgb(ACCENT_BLUE))
            })
            .child(if entry_type == EntryType::Image && path_exists {
                let img_path = std::path::Path::new(&image_path);
                div()
                    .size(px(36.0))
                    .rounded_md()
                    .overflow_hidden()
                    .flex_shrink_0()
                    .bg(rgb(BG_SURFACE))
                    .child(img(img_path).size(px(36.0)))
            } else {
                div()
                    .size(px(36.0))
                    .rounded_md()
                    .bg(rgb(BG_SURFACE))
                    .flex()
                    .items_center()
                    .justify_center()
                    .flex_shrink_0()
                    .child(div().size(px(10.0)).rounded_full().bg(icon_color))
            })
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w_0()
                    .gap(px(3.0))
                    .child(
                        div()
                            .text_sm()
                            .text_color(if is_current {
                                rgb(TEXT_PRIMARY)
                            } else {
                                rgb(0xdddddd)
                            })
                            .when(is_current, |el| el.font_weight(gpui::FontWeight::MEDIUM))
                            .truncate()
                            .child(display_label),
                    )
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(div().text_color(icon_color).text_xs().child(type_label))
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(rgb(TEXT_MUTED))
                                    .child("\u{00b7}"),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(rgb(TEXT_MUTED))
                                    .child(timestamp_str),
                            ),
                    ),
            )
            .when(id != CURRENT_ENTRY_ID, |el| {
                el.child(
                    div()
                        .id(SharedString::from(format!("remove-{}", id)))
                        .size(px(24.0))
                        .rounded_md()
                        .flex()
                        .items_center()
                        .justify_center()
                        .flex_shrink_0()
                        .text_color(rgb(TEXT_MUTED))
                        .hover(|style| style.bg(rgba(0xff453a20)).text_color(rgb(DANGER)))
                        .cursor_pointer()
                        .text_sm()
                        .child("\u{00d7}")
                        .on_click(move |_, _, app| {
                            view_remove.update(app, |this, cx| {
                                this.remove(id, cx);
                            });
                        }),
                )
            })
            .on_click(move |_, _, app| {
                view.update(app, |this, cx| {
                    this.select_entry(id, cx);
                });
            })
    }
}

impl Render for ClipzApp {
    fn render(&mut self, window: &mut Window, cx: &mut GpuiContext<Self>) -> impl IntoElement {
        self.poll_backend();

        let view_entity = cx.entity();
        let filtered_entries = self.filtered();
        let entry_count = filtered_entries.len();

        if self.focused_index.is_none() && !filtered_entries.is_empty() {
            self.focused_index = Some(0);
        }

        let focused_index = self.focused_index;
        let view_keyboard = view_entity.clone();

        let entries: Vec<_> = filtered_entries
            .iter()
            .enumerate()
            .map(|(idx, entry)| self.render_entry(entry, idx, focused_index, view_entity.clone()))
            .collect();

        let view_entity = cx.entity();
        let view_clear = view_entity.clone();

        window.focus(&self.focus_handle);

        div()
            .track_focus(&self.focus_handle)
            .flex()
            .flex_col()
            .size_full()
            .bg(rgb(BG_BASE))
            .text_color(rgb(TEXT_PRIMARY))
            .on_key_down(move |evt, _, app| {
                view_keyboard.update(app, |this, cx| {
                    let filtered = this.filtered();
                    if filtered.is_empty() {
                        return;
                    }
                    let key_str = format!("{:?}", evt.keystroke.key).to_lowercase();
                    match key_str.as_str() {
                        "\"up\"" | "\"arrowup\"" | "up" | "arrowup" => {
                            if let Some(current_idx) = this.focused_index {
                                if current_idx > 0 {
                                    this.focused_index = Some(current_idx - 1);
                                } else {
                                    this.focused_index = Some(filtered.len() - 1);
                                }
                            } else {
                                this.focused_index = Some(0);
                            }
                            this.update_scroll_to_focused();
                            cx.notify();
                        }
                        "\"down\"" | "\"arrowdown\"" | "down" | "arrowdown" => {
                            if let Some(current_idx) = this.focused_index {
                                if current_idx < filtered.len() - 1 {
                                    this.focused_index = Some(current_idx + 1);
                                } else {
                                    this.focused_index = Some(0);
                                }
                            } else {
                                this.focused_index = Some(0);
                            }
                            this.update_scroll_to_focused();
                            cx.notify();
                        }
                        "\"enter\"" | "enter" | "\"return\"" | "return" => {
                            if let Some(idx) = this.focused_index {
                                if let Some(entry) = filtered.get(idx) {
                                    this.select_entry(entry.id, cx);
                                }
                            }
                        }
                        _ => {}
                    }
                });
            })
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .bg(rgb(BG_SURFACE))
                    .px_4()
                    .py_3()
                    .border_b_1()
                    .border_color(rgb(BORDER_SUBTLE))
                    .flex_shrink_0()
                    .child(
                        div().flex().items_center().gap_2().child(
                            div()
                                .text_base()
                                .font_weight(gpui::FontWeight::BOLD)
                                .text_color(rgb(TEXT_PRIMARY))
                                .child("Clipz"),
                        ),
                    )
                    .child(
                        div()
                            .px_2()
                            .py(px(2.0))
                            .rounded_md()
                            .bg(rgb(BORDER_SUBTLE))
                            .text_xs()
                            .text_color(rgb(TEXT_SECONDARY))
                            .child(format!("{}", entry_count)),
                    ),
            )
            .child(
                div()
                    .id(SharedString::from("entry-list"))
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .py_2()
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .w_full()
                            .children(entries)
                            .mt(px(-self.scroll_position)),
                    ),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .px_4()
                    .py_2()
                    .bg(rgb(BG_SURFACE))
                    .border_t_1()
                    .border_color(rgb(BORDER_SUBTLE))
                    .flex_shrink_0()
                    .child(
                        div()
                            .text_xs()
                            .text_color(rgb(TEXT_MUTED))
                            .child("\u{2191}\u{2193} navigate \u{00b7} \u{23ce} copy"),
                    )
                    .child(
                        div()
                            .id(SharedString::from("clear-button"))
                            .px_3()
                            .py_1()
                            .rounded_md()
                            .text_color(rgb(TEXT_MUTED))
                            .hover(|style| style.bg(rgba(0xff453a20)).text_color(rgb(DANGER)))
                            .cursor_pointer()
                            .text_xs()
                            .child("Clear All")
                            .on_click(move |_, _, app| {
                                view_clear.update(app, |this, cx| this.clear(cx));
                            }),
                    ),
            )
    }
}

#[cfg(target_os = "macos")]
#[allow(unexpected_cfgs)]
fn configure_window_for_spaces() {
    unsafe {
        let ns_app: *mut objc::runtime::Object =
            msg_send![objc::class!(NSApplication), sharedApplication];

        let windows: *mut objc::runtime::Object = msg_send![ns_app, windows];
        let count: usize = msg_send![windows, count];

        if count > 0 {
            let window: *mut objc::runtime::Object = msg_send![windows, objectAtIndex: count - 1];
            let _: () = msg_send![
                window,
                setCollectionBehavior: NSWindowCollectionBehavior::NSWindowCollectionBehaviorMoveToActiveSpace
            ];
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn configure_window_for_spaces() {}

fn main() {
    Application::new()
        .with_assets(FileSystemAssets)
        .run(|cx: &mut App| {
            let bounds = Bounds::centered(None, size(px(480.), px(520.)), cx);
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    focus: true,
                    show: true,
                    ..Default::default()
                },
                |window, cx| cx.new(|cx| ClipzApp::new(window, cx)),
            )
            .unwrap();

            #[cfg(target_os = "macos")]
            configure_window_for_spaces();

            cx.activate(true);
        });
}
