#![allow(unexpected_cfgs)]

use std::{
    io::{BufRead, BufReader, Write},
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, Sender},
        Arc, Mutex,
    },
    thread,
    time::Duration,
};

use anyhow::{anyhow, Context, Result};
use global_hotkey::{
    hotkey::{Code, HotKey, Modifiers},
    GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState,
};
use gpui::{
    div, img, point, prelude::*, px, rgb, rgba, size, App, Application, AssetSource, Bounds,
    Context as GpuiContext, Entity, FocusHandle, Focusable, IntoElement, Pixels, Point,
    ScrollHandle, SharedString, Window, WindowBackgroundAppearance, WindowBounds, WindowHandle,
    WindowKind, WindowOptions,
};
use serde::Deserialize;

#[cfg(target_os = "macos")]
use {
    cocoa::appkit::{NSSquareStatusItemLength, NSStatusBar, NSStatusItem},
    cocoa::base::{id, nil},
    cocoa::foundation::NSString,
    objc::{
        class,
        declare::ClassDecl,
        msg_send,
        runtime::{Object, Sel},
        sel, sel_impl,
    },
};

// ---------- Global for menu bar click signal ----------

static MENU_BAR_CLICKED: AtomicBool = AtomicBool::new(false);
static POPOVER_SHOULD_CLOSE: AtomicBool = AtomicBool::new(false);

#[cfg(target_os = "macos")]
static mut STATUS_ITEM: *mut Object = std::ptr::null_mut();

// ---------- Backend types ----------

#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "type")]
enum BackendMessage {
    #[serde(rename = "entries")]
    Entries { data: Vec<Entry> },
    #[serde(rename = "select-success")]
    SelectSuccess,
    #[serde(rename = "remove-success")]
    RemoveSuccess,
    #[serde(rename = "pin-toggled")]
    PinToggled,
    #[serde(rename = "success")]
    Success,
    #[serde(rename = "ready")]
    Ready {
        #[serde(default)]
        #[serde(rename = "supportsIdCommands")]
        supports_id_commands: bool,
    },
    #[serde(other)]
    Unknown,
}

#[derive(Clone, Debug, Deserialize)]
struct Entry {
    id: u64,
    content: String,
    timestamp: i64,
    #[serde(default)]
    #[serde(rename = "type")]
    entry_type: EntryType,
    #[serde(default)]
    #[serde(rename = "isCurrent")]
    is_current: bool,
    #[serde(default)]
    pinned: bool,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
enum EntryType {
    #[default]
    Text,
    Image,
    File,
    Url,
    Color,
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

fn parse_hex_color(s: &str) -> Option<u32> {
    let s = s.trim();
    let hex = s.strip_prefix('#')?;
    match hex.len() {
        3 => {
            // #RGB → #RRGGBB
            let r = u8::from_str_radix(&hex[0..1], 16).ok()?;
            let g = u8::from_str_radix(&hex[1..2], 16).ok()?;
            let b = u8::from_str_radix(&hex[2..3], 16).ok()?;
            Some(((r * 17) as u32) << 16 | ((g * 17) as u32) << 8 | (b * 17) as u32)
        }
        6 | 8 => {
            // #RRGGBB or #RRGGBBAA — ignore alpha, take first 6
            u32::from_str_radix(&hex[..6], 16).ok()
        }
        _ => None,
    }
}

fn format_timestamp(timestamp: i64) -> String {
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

fn icon_color_for_type(et: &EntryType) -> u32 {
    match et {
        EntryType::Text => ACCENT_BLUE,
        EntryType::Image => ACCENT_ORANGE,
        EntryType::File => ACCENT_GREEN,
        EntryType::Url => ACCENT_PURPLE,
        EntryType::Color => ACCENT_PINK,
    }
}

fn type_label_for_type(et: &EntryType) -> &'static str {
    match et {
        EntryType::Text => "Text",
        EntryType::Image => "Image",
        EntryType::File => "File",
        EntryType::Url => "URL",
        EntryType::Color => "Color",
    }
}

const TEXT_PRIMARY: u32 = 0xf7f4ee;
const TEXT_SECONDARY: u32 = 0xd7d0c2;
const TEXT_MUTED: u32 = 0xa69c89;
const TEXT_DIM: u32 = 0x8a7f6b;
const ACCENT_BLUE: u32 = 0x5ac8fa;
const ACCENT_ORANGE: u32 = 0xff9f0a;
const ACCENT_GREEN: u32 = 0x30d158;
const ACCENT_PURPLE: u32 = 0xbf5af2;
const ACCENT_PINK: u32 = 0xff375f;
const DANGER: u32 = 0xff453a;
const SURFACE_BASE: u32 = 0x14110bf2;
const SURFACE_BORDER: u32 = 0xffffff24;
const SURFACE_ROW: u32 = 0xffffff08;
const SURFACE_ROW_FOCUSED: u32 = 0xffffff14;
const SURFACE_ROW_CURRENT: u32 = 0xffffff20;
const SURFACE_ROW_HOVER: u32 = 0xffffff18;
const SURFACE_ICON_WELL: u32 = 0xffffff10;

// ---------- NSStatusItem setup (macOS) ----------

#[cfg(target_os = "macos")]
extern "C" fn status_item_action(_this: &Object, _cmd: Sel, _sender: id) {
    MENU_BAR_CLICKED.store(true, Ordering::SeqCst);
}

#[cfg(target_os = "macos")]
fn setup_menu_bar_icon() {
    unsafe {
        let status_bar = NSStatusBar::systemStatusBar(nil);
        let status_item = status_bar.statusItemWithLength_(NSSquareStatusItemLength);
        // Retain so it doesn't get deallocated
        let _: () = msg_send![status_item, retain];

        let button: id = status_item.button();

        // Use NSImage from SF Symbols (macOS 11+) for a native menu bar look
        let symbol_name = cocoa::foundation::NSString::alloc(nil).init_str("clipboard");
        let ns_image: id = msg_send![class!(NSImage), imageWithSystemSymbolName: symbol_name
                                                      accessibilityDescription: nil];
        if !ns_image.is_null() {
            let _: () = msg_send![button, setImage: ns_image];
        } else {
            // Fallback for older macOS
            let title = cocoa::foundation::NSString::alloc(nil).init_str("\u{1f4cb}");
            let _: () = msg_send![button, setTitle: title];
        }

        // Create a handler class for the click action
        let superclass = class!(NSObject);
        let mut decl = ClassDecl::new("StatusItemHandler", superclass).unwrap();
        decl.add_method(
            sel!(handleClick:),
            status_item_action as extern "C" fn(&Object, Sel, id),
        );
        let handler_class = decl.register();

        let handler: id = msg_send![handler_class, new];
        let _: () = msg_send![button, setTarget: handler];
        let _: () = msg_send![button, setAction: sel!(handleClick:)];

        STATUS_ITEM = status_item;
    }
}

#[cfg(target_os = "macos")]
fn get_status_item_position() -> Option<Point<Pixels>> {
    unsafe {
        let status_item = STATUS_ITEM;
        if status_item.is_null() {
            return None;
        }

        let button: id = msg_send![status_item, button];
        if button.is_null() {
            return None;
        }

        let button_window: id = msg_send![button, window];
        if button_window.is_null() {
            return None;
        }

        // macOS uses bottom-left origin; gpui uses top-left origin.
        // Get screen height to convert.
        let screen: id = msg_send![button_window, screen];
        let screen_frame: cocoa::foundation::NSRect = msg_send![screen, frame];
        let screen_height = screen_frame.size.height;

        // Get the button's window frame (in macOS bottom-left coords)
        let frame: cocoa::foundation::NSRect = msg_send![button_window, frame];

        // Convert to top-left coords: the bottom of the status item = top of popover
        let x = frame.origin.x + frame.size.width / 2.0 - 160.0; // center horizontally
        let y = screen_height - frame.origin.y; // bottom of status item in top-left coords

        Some(point(px(x as f32), px(y as f32)))
    }
}

#[cfg(not(target_os = "macos"))]
fn setup_menu_bar_icon() {}

#[cfg(not(target_os = "macos"))]
fn get_status_item_position() -> Option<Point<Pixels>> {
    None
}

// ---------- Shared entries for popover ----------

type SharedEntries = Arc<Mutex<Vec<Entry>>>;

// ---------- MenuBarPopover ----------

struct MenuBarPopover {
    entries: SharedEntries,
    backend_tx: Sender<String>,
    supports_id_commands: Arc<AtomicBool>,
    focus_handle: FocusHandle,
    focused_index: Option<usize>,
    scroll_handle: ScrollHandle,
    _activation_sub: gpui::Subscription,
}

impl Focusable for MenuBarPopover {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl MenuBarPopover {
    fn new(
        entries: SharedEntries,
        backend_tx: Sender<String>,
        supports_id_commands: Arc<AtomicBool>,
        window: &mut Window,
        cx: &mut GpuiContext<Self>,
    ) -> Self {
        let focus_handle = cx.focus_handle();
        window.focus(&focus_handle);

        let activation_sub = cx.observe_window_activation(window, |_this, window, _cx| {
            if !window.is_window_active() {
                POPOVER_SHOULD_CLOSE.store(true, Ordering::SeqCst);
            }
        });

        Self {
            entries,
            backend_tx,
            supports_id_commands,
            focus_handle,
            focused_index: Some(0),
            scroll_handle: ScrollHandle::new(),
            _activation_sub: activation_sub,
        }
    }

    fn select_entry(&self, id: u64, legacy_index: usize) {
        if self.supports_id_commands.load(Ordering::Acquire) {
            let _ = self.backend_tx.send(format!("select-entry-id:{id}"));
        } else {
            let _ = self.backend_tx.send(format!("select-entry:{legacy_index}"));
        }
        let _ = self.backend_tx.send("get-entries".into());
    }

    fn remove_entry(&self, id: u64, legacy_index: usize) {
        if self.supports_id_commands.load(Ordering::Acquire) {
            let _ = self.backend_tx.send(format!("remove-entry-id:{id}"));
        } else {
            let _ = self.backend_tx.send(format!("remove-entry:{legacy_index}"));
        }
        let _ = self.backend_tx.send("get-entries".into());
    }

    fn toggle_pin(&self, id: u64, legacy_index: usize) {
        if self.supports_id_commands.load(Ordering::Acquire) {
            let _ = self.backend_tx.send(format!("toggle-pin-id:{id}"));
        } else {
            let _ = self.backend_tx.send(format!("toggle-pin:{legacy_index}"));
        }
    }

    fn render_popover_entry(
        entry: &Entry,
        idx: usize,
        focused_index: Option<usize>,
        view_entity: gpui::Entity<Self>,
    ) -> impl IntoElement + 'static {
        let is_focused = focused_index == Some(idx);
        let id = entry.id;
        let content = entry.content.clone();
        let entry_type = entry.entry_type.clone();
        let is_current = entry.is_current;
        let is_pinned = entry.pinned;
        let image_path = entry.content.clone();
        let path_exists = std::path::Path::new(&image_path).exists();
        let timestamp_str = format_timestamp(entry.timestamp);
        let ic = icon_color_for_type(&entry.entry_type);
        let tl = type_label_for_type(&entry.entry_type);

        let display_label: String = match &entry_type {
            EntryType::Image | EntryType::File => {
                if path_exists {
                    filename_from_path(&content)
                } else {
                    content.clone()
                }
            }
            _ => content.clone(),
        };

        let row_bg = if is_current {
            rgba(SURFACE_ROW_CURRENT)
        } else if is_focused {
            rgba(SURFACE_ROW_FOCUSED)
        } else {
            rgba(SURFACE_ROW)
        };

        let view = view_entity.clone();
        let view_remove = view_entity.clone();
        let view_pin = view_entity.clone();
        let legacy_index = idx + 1;
        let entry_id_str = SharedString::from(format!("pop-entry-{}", id));

        div()
            .id(entry_id_str)
            .mx(px(6.0))
            .mb(px(1.0))
            .flex()
            .items_center()
            .gap(px(8.0))
            .px(px(8.0))
            .py(px(7.0))
            .bg(row_bg)
            .rounded_lg()
            .hover(|style| style.bg(rgba(SURFACE_ROW_HOVER)))
            .cursor_pointer()
            .child(if entry_type == EntryType::Image && path_exists {
                let img_path = std::path::Path::new(&image_path);
                div()
                    .size(px(28.0))
                    .rounded(px(6.0))
                    .overflow_hidden()
                    .flex_shrink_0()
                    .child(img(img_path).size(px(28.0)))
            } else if entry_type == EntryType::Color {
                let swatch_color = parse_hex_color(&content).unwrap_or(ACCENT_PINK);
                div()
                    .size(px(28.0))
                    .rounded(px(6.0))
                    .bg(rgba(SURFACE_ICON_WELL))
                    .flex()
                    .items_center()
                    .justify_center()
                    .flex_shrink_0()
                    .child(
                        div()
                            .size(px(16.0))
                            .rounded(px(4.0))
                            .bg(rgb(swatch_color))
                            .border_1()
                            .border_color(rgba(0xffffff30)),
                    )
            } else {
                div()
                    .size(px(28.0))
                    .rounded(px(6.0))
                    .bg(rgba(SURFACE_ICON_WELL))
                    .flex()
                    .items_center()
                    .justify_center()
                    .flex_shrink_0()
                    .child(div().size(px(8.0)).rounded_full().bg(rgb(ic)))
            })
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w_0()
                    .gap(px(1.0))
                    .child(
                        div()
                            .text_xs()
                            .text_color(rgb(TEXT_PRIMARY))
                            .truncate()
                            .child(display_label),
                    )
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_1()
                            .child(div().text_color(rgb(ic)).text_size(px(10.0)).child(tl))
                            .when(is_pinned, |el| {
                                el.child(
                                    div()
                                        .text_size(px(10.0))
                                        .text_color(rgb(TEXT_DIM))
                                        .child("\u{00b7}"),
                                )
                                .child(
                                    div()
                                        .text_size(px(10.0))
                                        .text_color(rgb(ACCENT_ORANGE))
                                        .child("Pinned"),
                                )
                            })
                            .child(
                                div()
                                    .text_size(px(10.0))
                                    .text_color(rgb(TEXT_DIM))
                                    .child("\u{00b7}"),
                            )
                            .child(
                                div()
                                    .text_size(px(10.0))
                                    .text_color(rgb(TEXT_SECONDARY))
                                    .child(timestamp_str),
                            ),
                    ),
            )
            .child(
                div()
                    .id(SharedString::from(format!("pop-pin-{}", id)))
                    .size(px(22.0))
                    .rounded(px(6.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .flex_shrink_0()
                    .text_size(px(9.0))
                    .text_color(if is_pinned {
                        rgb(ACCENT_ORANGE)
                    } else {
                        rgb(TEXT_MUTED)
                    })
                    .hover(|style| style.bg(rgba(0xff9f0a18)).text_color(rgb(ACCENT_ORANGE)))
                    .cursor_pointer()
                    .child(if is_pinned { "\u{25CF}" } else { "\u{25CB}" })
                    .on_click(move |_, _, app| {
                        app.stop_propagation();
                        view_pin.update(app, |this, cx| {
                            this.toggle_pin(id, legacy_index);
                            cx.notify();
                        });
                    }),
            )
            .when(!is_current, |el| {
                el.child(
                    div()
                        .id(SharedString::from(format!("pop-remove-{}", id)))
                        .size(px(22.0))
                        .rounded(px(6.0))
                        .flex()
                        .items_center()
                        .justify_center()
                        .flex_shrink_0()
                        .text_color(rgb(TEXT_MUTED))
                        .hover(|style| style.bg(rgba(0xff453a20)).text_color(rgb(DANGER)))
                        .cursor_pointer()
                        .text_xs()
                        .child("\u{00d7}")
                        .on_click(move |_, _, app| {
                            app.stop_propagation();
                            view_remove.update(app, |this, cx| {
                                this.remove_entry(id, legacy_index);
                                cx.notify();
                            });
                        }),
                )
            })
            .on_click(move |_, _, app| {
                view.update(app, |this, cx| {
                    this.select_entry(id, legacy_index);
                    // Signal to close popover after selecting
                    MENU_BAR_CLICKED.store(true, Ordering::SeqCst);
                    cx.notify();
                });
            })
    }
}

impl Render for MenuBarPopover {
    fn render(&mut self, window: &mut Window, cx: &mut GpuiContext<Self>) -> impl IntoElement {
        let entries = self.entries.lock().unwrap().clone();
        let entry_count = entries.len();
        let view_entity = cx.entity();

        if self.focused_index.is_none() && !entries.is_empty() {
            self.focused_index = Some(0);
        }
        if let Some(idx) = self.focused_index {
            if idx >= entries.len() {
                self.focused_index = if entries.is_empty() {
                    None
                } else {
                    Some(entries.len() - 1)
                };
            }
        }
        let focused_index = self.focused_index;

        let rendered_entries: Vec<_> = entries
            .iter()
            .enumerate()
            .map(|(idx, entry)| {
                Self::render_popover_entry(entry, idx, focused_index, view_entity.clone())
            })
            .collect();

        let view_clear = view_entity.clone();
        let view_keyboard = view_entity.clone();
        let entry_count_for_keys = entries.len();

        window.focus(&self.focus_handle);

        div()
            .track_focus(&self.focus_handle)
            .flex()
            .flex_col()
            .size_full()
            .bg(rgba(SURFACE_BASE))
            .border_1()
            .border_color(rgba(SURFACE_BORDER))
            .rounded_xl()
            .overflow_hidden()
            .text_color(rgb(TEXT_PRIMARY))
            .on_key_down(move |evt, _, app| {
                view_keyboard.update(app, |this, cx| {
                    let count = entry_count_for_keys;
                    if count == 0 {
                        return;
                    }
                    let key_str = format!("{:?}", evt.keystroke.key).to_lowercase();
                    match key_str.as_str() {
                        "\"up\"" | "\"arrowup\"" | "up" | "arrowup" => {
                            let new_idx = if let Some(idx) = this.focused_index {
                                if idx > 0 {
                                    idx - 1
                                } else {
                                    count - 1
                                }
                            } else {
                                0
                            };
                            this.focused_index = Some(new_idx);
                            this.scroll_handle.scroll_to_item(new_idx);
                            cx.notify();
                        }
                        "\"down\"" | "\"arrowdown\"" | "down" | "arrowdown" => {
                            let new_idx = if let Some(idx) = this.focused_index {
                                if idx < count - 1 {
                                    idx + 1
                                } else {
                                    0
                                }
                            } else {
                                0
                            };
                            this.focused_index = Some(new_idx);
                            this.scroll_handle.scroll_to_item(new_idx);
                            cx.notify();
                        }
                        "\"enter\"" | "enter" | "\"return\"" | "return" => {
                            if let Some(idx) = this.focused_index {
                                let entries = this.entries.lock().unwrap().clone();
                                if let Some(entry) = entries.get(idx) {
                                    this.select_entry(entry.id, idx + 1);
                                    MENU_BAR_CLICKED.store(true, Ordering::SeqCst);
                                }
                            }
                            cx.notify();
                        }
                        "\"escape\"" | "escape" => {
                            MENU_BAR_CLICKED.store(true, Ordering::SeqCst);
                            cx.notify();
                        }
                        _ => {}
                    }
                });
            })
            // Entry list
            .child(
                div()
                    .id(SharedString::from("popover-entry-list"))
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .track_scroll(&self.scroll_handle)
                    .pt(px(6.0))
                    .pb(px(2.0))
                    .children(rendered_entries),
            )
            // Footer
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .px_3()
                    .py(px(6.0))
                    .border_t_1()
                    .border_color(rgba(SURFACE_BORDER))
                    .flex_shrink_0()
                    .child(
                        div()
                            .text_size(px(10.0))
                            .text_color(rgb(TEXT_SECONDARY))
                            .child(format!("{} items", entry_count)),
                    )
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(
                                div()
                                    .id(SharedString::from("popover-clear"))
                                    .px_2()
                                    .py(px(2.0))
                                    .rounded(px(6.0))
                                    .text_size(px(10.0))
                                    .text_color(rgb(TEXT_SECONDARY))
                                    .hover(|style| {
                                        style.bg(rgba(0xff453a18)).text_color(rgb(DANGER))
                                    })
                                    .cursor_pointer()
                                    .child("Clear All")
                                    .on_click(move |_, _, app| {
                                        view_clear.update(app, |this, cx| {
                                            let _ = this.backend_tx.send("clear".into());
                                            let _ = this.backend_tx.send("get-entries".into());
                                            cx.notify();
                                        });
                                    }),
                            )
                            .child({
                                let quit_tx = self.backend_tx.clone();
                                div()
                                    .id(SharedString::from("popover-quit"))
                                    .px_2()
                                    .py(px(2.0))
                                    .rounded(px(6.0))
                                    .text_size(px(10.0))
                                    .text_color(rgb(TEXT_SECONDARY))
                                    .hover(|style| {
                                        style.bg(rgba(0xff453a18)).text_color(rgb(DANGER))
                                    })
                                    .cursor_pointer()
                                    .child("Quit")
                                    .on_click(move |_, _, _app| {
                                        let _ = quit_tx.send("quit".into());
                                        thread::sleep(Duration::from_millis(150));
                                        std::process::exit(0);
                                    })
                            }),
                    ),
            )
    }
}

// ---------- AppState (headless, no window) ----------

struct AppState {
    backend: Option<BackendHandle>,
    shared_entries: SharedEntries,
    supports_id_commands: Arc<AtomicBool>,
    _hotkey_manager: GlobalHotKeyManager,
    hotkey_rx: Receiver<()>,
    popover_handle: Option<WindowHandle<MenuBarPopover>>,
}

impl AppState {
    fn toggle_popover(&mut self, cx: &mut App) {
        if let Some(handle) = self.popover_handle.take() {
            let _ = handle.update(cx, |_, window, _| {
                window.remove_window();
            });
            return;
        }

        let pos = get_status_item_position();
        let popover_width = 320.0_f32;
        let popover_height = 400.0_f32;

        let bounds = if let Some(p) = pos {
            Bounds {
                origin: p,
                size: size(px(popover_width), px(popover_height)),
            }
        } else {
            Bounds::centered(None, size(px(popover_width), px(popover_height)), cx)
        };

        let shared = self.shared_entries.clone();
        let backend_tx = self.backend.as_ref().map(|b| b.tx.clone());
        let supports_id_commands = self.supports_id_commands.clone();

        if let Some(tx) = backend_tx {
            let handle = cx
                .open_window(
                    WindowOptions {
                        window_bounds: Some(WindowBounds::Windowed(bounds)),
                        titlebar: None,
                        focus: true,
                        show: true,
                        kind: WindowKind::PopUp,
                        is_movable: false,
                        is_resizable: false,
                        is_minimizable: false,
                        window_background: WindowBackgroundAppearance::Blurred,
                        ..Default::default()
                    },
                    |window, cx| {
                        cx.new(|cx| {
                            MenuBarPopover::new(shared, tx, supports_id_commands, window, cx)
                        })
                    },
                )
                .ok();

            self.popover_handle = handle;
        }
    }

    fn poll_backend(&mut self) -> bool {
        let mut entries_changed = false;
        if let Some(backend) = &self.backend {
            while let Ok(msg) = backend.rx.try_recv() {
                match msg {
                    BackendMessage::Entries { data } => {
                        if let Ok(mut shared) = self.shared_entries.lock() {
                            *shared = data;
                        }
                        entries_changed = true;
                    }
                    BackendMessage::SelectSuccess
                    | BackendMessage::RemoveSuccess
                    | BackendMessage::PinToggled
                    | BackendMessage::Success => {
                        if let Err(e) = backend.send("get-entries") {
                            eprintln!("Failed to refresh entries: {}", e);
                        }
                    }
                    BackendMessage::Ready {
                        supports_id_commands,
                    } => {
                        self.supports_id_commands
                            .store(supports_id_commands, Ordering::Release);
                        if let Err(e) = backend.send("get-entries") {
                            eprintln!("Failed to refresh entries: {}", e);
                        }
                    }
                    BackendMessage::Unknown => {}
                }
            }
        }
        entries_changed
    }
}

fn start_poll_loop(app_state: Entity<AppState>, cx: &mut App) {
    let bg_executor = cx.background_executor().clone();
    let async_cx = cx.to_async();
    cx.foreground_executor()
        .spawn(async move {
            loop {
                bg_executor.timer(Duration::from_millis(100)).await;
                let result = async_cx.update(|cx| {
                    app_state.update(cx, |state, cx| {
                        let mut needs_notify = false;

                        // Handle hotkey
                        while state.hotkey_rx.try_recv().is_ok() {
                            state.toggle_popover(cx);
                            needs_notify = true;
                        }

                        if state.poll_backend() {
                            needs_notify = true;
                        }

                        // Menu bar click toggle
                        if MENU_BAR_CLICKED.swap(false, Ordering::SeqCst) {
                            state.toggle_popover(cx);
                            needs_notify = true;
                        }

                        // Close popover if it lost focus
                        if POPOVER_SHOULD_CLOSE.swap(false, Ordering::SeqCst) {
                            if let Some(handle) = state.popover_handle.take() {
                                let _ = handle.update(cx, |_, window, _| {
                                    window.remove_window();
                                });
                            }
                        }

                        if needs_notify {
                            if let Some(handle) = state.popover_handle {
                                let _ = handle.update(cx, |_, _, cx| {
                                    cx.notify();
                                });
                            }
                        }
                    });
                });
                if result.is_err() {
                    break;
                }
            }
        })
        .detach();
}

#[cfg(target_os = "macos")]
fn set_activation_policy_accessory() {
    unsafe {
        let ns_app: id = msg_send![class!(NSApplication), sharedApplication];
        // NSApplicationActivationPolicyAccessory = 1
        let _: () = msg_send![ns_app, setActivationPolicy: 1i64];

        // Force dark vibrant appearance so the blur material is always dark,
        // regardless of wallpaper or system theme.
        let name = NSString::alloc(nil).init_str("NSAppearanceNameVibrantDark");
        let appearance: id = msg_send![class!(NSAppearance), appearanceNamed: name];
        if !appearance.is_null() {
            let _: () = msg_send![ns_app, setAppearance: appearance];
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn set_activation_policy_accessory() {}

fn main() {
    Application::new()
        .with_assets(FileSystemAssets)
        .run(|cx: &mut App| {
            set_activation_policy_accessory();
            setup_menu_bar_icon();

            let hotkey_manager =
                GlobalHotKeyManager::new().expect("failed to create hotkey manager");
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

            let shared_entries: SharedEntries = Arc::new(Mutex::new(Vec::new()));
            let supports_id_commands = Arc::new(AtomicBool::new(false));
            let backend = BackendHandle::start().ok();

            if let Some(ref b) = backend {
                if let Err(e) = b.send("get-entries") {
                    eprintln!("Failed to refresh entries: {}", e);
                }
            }

            let app_state = cx.new(|_| AppState {
                backend,
                shared_entries,
                supports_id_commands,
                _hotkey_manager: hotkey_manager,
                hotkey_rx,
                popover_handle: None,
            });

            start_poll_loop(app_state, cx);
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backend_message_accepts_id_and_legacy_index_fields() {
        let from_id: BackendMessage =
            serde_json::from_str(r#"{"type":"select-success","id":42}"#).unwrap();
        assert!(matches!(from_id, BackendMessage::SelectSuccess));

        let from_index: BackendMessage =
            serde_json::from_str(r#"{"type":"remove-success","index":7}"#).unwrap();
        assert!(matches!(from_index, BackendMessage::RemoveSuccess));
    }

    #[test]
    fn entries_payload_parses_escaped_control_characters() {
        let msg: BackendMessage = serde_json::from_str(
            r#"{"type":"entries","data":[{"id":1,"content":"hello\n\b\f","timestamp":1000,"type":"text","isCurrent":true,"pinned":false}]}"#,
        )
        .unwrap();

        match msg {
            BackendMessage::Entries { data } => {
                assert_eq!(data.len(), 1);
                assert_eq!(data[0].content, "hello\n\u{0008}\u{000C}");
                assert!(data[0].is_current);
            }
            _ => panic!("expected entries payload"),
        }
    }
}
