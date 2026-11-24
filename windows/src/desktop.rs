use crate::cache::{self, Candidate, Recovery, Roots};
use native_windows_gui as nwg;
use std::cell::RefCell;
use std::io;
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver, Sender};

enum Items {
    Caches(cache::Review),
    Recovery(Vec<Recovery>),
    History(Vec<(String, cache::Receipt)>),
}

struct Update {
    items: io::Result<Items>,
    receipt: Option<String>,
    select_copies: Vec<String>,
}

#[derive(Default)]
struct Controls {
    window: nwg::Window,
    heading: nwg::Label,
    status: nwg::Label,
    list: nwg::ListBox<String>,
    detail: nwg::TextBox,
    scan: nwg::Button,
    recovery: nwg::Button,
    action: nwg::Button,
    delete: nwg::Button,
    history: nwg::Button,
    notice: nwg::Notice,
}

struct Desktop {
    controls: Controls,
    roots: Roots,
    items: RefCell<Items>,
    tx: Sender<Update>,
    rx: Receiver<Update>,
}

pub fn run() {
    if let Err(error) = run_window() {
        nwg::error_message("Diskfolio", &error.to_string());
    }
}

fn run_window() -> Result<(), Box<dyn std::error::Error>> {
    let desktop = build_window(Roots::current()?)?;
    let handler = bind_events(&desktop);
    desktop.scan();
    nwg::dispatch_thread_events();
    nwg::unbind_event_handler(&handler);
    Ok(())
}

fn build_window(roots: Roots) -> Result<Rc<Desktop>, nwg::NwgError> {
    nwg::init()?;
    nwg::Font::set_global_family("Segoe UI")?;
    let mut controls = Controls::default();

    nwg::Window::builder()
        .flags(nwg::WindowFlags::WINDOW | nwg::WindowFlags::VISIBLE)
        .title("Diskfolio")
        .size((680, 442))
        .center(true)
        .build(&mut controls.window)?;
    let window = &controls.window;

    nwg::Label::builder()
        .text("App Caches")
        .position((22, 18))
        .size((635, 22))
        .parent(window)
        .build(&mut controls.heading)?;
    nwg::Label::builder()
        .position((22, 50))
        .size((635, 44))
        .parent(window)
        .build(&mut controls.status)?;
    nwg::ListBox::builder()
        .flags(
            nwg::ListBoxFlags::VISIBLE
                | nwg::ListBoxFlags::TAB_STOP
                | nwg::ListBoxFlags::MULTI_SELECT,
        )
        .position((22, 104))
        .size((635, 193))
        .parent(window)
        .build(&mut controls.list)?;
    nwg::TextBox::builder()
        .readonly(true)
        .flags(
            nwg::TextBoxFlags::VISIBLE | nwg::TextBoxFlags::VSCROLL | nwg::TextBoxFlags::TAB_STOP,
        )
        .position((22, 308))
        .size((635, 62))
        .parent(window)
        .build(&mut controls.detail)?;
    nwg::Button::builder()
        .text("Scan caches")
        .position((22, 380))
        .size((112, 33))
        .parent(window)
        .build(&mut controls.scan)?;
    nwg::Button::builder()
        .text("Recovery")
        .position((144, 380))
        .size((112, 33))
        .parent(window)
        .build(&mut controls.recovery)?;
    nwg::Button::builder()
        .text("Move to recovery")
        .position((479, 380))
        .size((178, 33))
        .parent(window)
        .build(&mut controls.action)?;
    nwg::Button::builder()
        .text("Delete selected…")
        .position((334, 380))
        .size((135, 33))
        .parent(window)
        .build(&mut controls.delete)?;
    nwg::Button::builder()
        .text("History")
        .position((266, 380))
        .size((58, 33))
        .parent(window)
        .build(&mut controls.history)?;
    nwg::Notice::builder()
        .parent(window)
        .build(&mut controls.notice)?;

    controls.delete.set_visible(false);
    let (tx, rx) = mpsc::channel();
    Ok(Rc::new(Desktop {
        controls,
        roots,
        items: RefCell::new(Items::Caches(cache::Review::default())),
        tx,
        rx,
    }))
}

fn bind_events(desktop: &Rc<Desktop>) -> nwg::EventHandler {
    let weak = Rc::downgrade(desktop);
    nwg::full_bind_event_handler(&desktop.controls.window.handle, move |event, _, handle| {
        let Some(app) = weak.upgrade() else { return };
        match event {
            nwg::Event::OnWindowClose if handle == app.controls.window.handle => {
                nwg::stop_thread_dispatch()
            }
            nwg::Event::OnNotice if handle == app.controls.notice.handle => app.finish(),
            nwg::Event::OnListBoxSelect if handle == app.controls.list.handle => app.select(),
            nwg::Event::OnButtonClick if handle == app.controls.scan.handle => app.scan(),
            nwg::Event::OnButtonClick if handle == app.controls.recovery.handle => app.recoveries(),
            nwg::Event::OnButtonClick if handle == app.controls.action.handle => app.apply(false),
            nwg::Event::OnButtonClick if handle == app.controls.delete.handle => app.apply(true),
            nwg::Event::OnButtonClick if handle == app.controls.history.handle => app.history(),
            _ => (),
        }
    })
}

impl Desktop {
    fn work(&self, status: &str, operation: impl FnOnce(Roots) -> Update + Send + 'static) {
        self.controls.status.set_text(status);
        self.controls.detail.set_text("");
        self.controls.list.set_enabled(false);
        self.controls.scan.set_enabled(false);
        self.controls.recovery.set_enabled(false);
        self.controls.action.set_enabled(false);
        self.controls.delete.set_enabled(false);
        self.controls.history.set_enabled(false);
        let tx = self.tx.clone();
        let roots = self.roots.clone();
        let notice = self.controls.notice.sender();
        std::thread::spawn(move || {
            if tx.send(operation(roots)).is_ok() {
                notice.notice();
            }
        });
    }

    fn scan(&self) {
        self.work("Checking supported cache folders…", |roots| Update {
            items: Ok(Items::Caches(cache::preview(&roots))),
            receipt: None,
            select_copies: Vec::new(),
        });
    }

    fn recoveries(&self) {
        self.work("Reading recovery records…", |roots| Update {
            items: cache::recovery_items(&roots).map(Items::Recovery),
            receipt: None,
            select_copies: Vec::new(),
        });
    }

    fn history(&self) {
        self.work("Reading cleanup history…", |roots| Update {
            items: cache::history(&roots).map(Items::History),
            receipt: None,
            select_copies: Vec::new(),
        });
    }

    fn finish(&self) {
        let Ok(update) = self.rx.try_recv() else {
            return;
        };
        self.controls.list.set_enabled(true);
        self.controls.scan.set_enabled(true);
        self.controls.recovery.set_enabled(true);
        self.controls.history.set_enabled(true);
        let items = match update.items {
            Ok(items) => items,
            Err(error) => {
                self.controls.status.set_text(&error.to_string());
                self.controls.list.set_collection(Vec::new());
                return;
            }
        };
        let (heading, action, status, labels) = match &items {
            Items::Caches(review) => (
                "App Caches",
                "Move to recovery",
                format!(
                    "{} cache folders ready to review. {} skipped. Quit an app before moving its cache.",
                    review.candidates.len(),
                    review.skipped.len()
                ),
                review.candidates.iter().map(cache_label).collect(),
            ),
            Items::Recovery(items) => (
                "Recovery",
                "Restore selected cache",
                format!(
                    "{} held in recovery · {} folders.",
                    size_label(
                        items
                            .iter()
                            .filter_map(|item| item.bytes)
                            .fold(0u64, u64::saturating_add)
                    ),
                    items.len(),
                ),
                items
                    .iter()
                    .map(|item| {
                        format!(
                            "{} · {}",
                            item.label(),
                            if item.deleting {
                                "Delete again to finish".to_string()
                            } else {
                                item.bytes
                                    .map(size_label)
                                    .unwrap_or_else(|| "Size unknown".into())
                            }
                        )
                    })
                    .collect(),
            ),
            Items::History(receipts) => (
                "Cleanup History",
                "Show copies in Recovery",
                if receipts.is_empty() {
                    "No cleanup runs yet.".into()
                } else {
                    "Select a run to read its receipt.".into()
                },
                receipts
                    .iter()
                    .map(|(name, receipt)| format!("{} · {}", receipt.title, receipt_age(name)))
                    .collect(),
            ),
        };
        self.controls
            .delete
            .set_visible(matches!(&items, Items::Recovery(_)));
        self.controls.heading.set_text(heading);
        self.controls.action.set_text(action);
        self.controls.status.set_text(&match update.receipt {
            Some(receipt) => format!("{receipt}\r\n{status}"),
            None => status,
        });
        self.controls.list.set_collection(labels);
        if let Items::Recovery(items) = &items {
            for (index, item) in items.iter().enumerate() {
                if update.select_copies.contains(&item.id()) {
                    self.controls.list.multi_add_selection(index);
                }
            }
        }
        self.items.replace(items);
        self.select();
    }

    fn select(&self) {
        let items = self.items.borrow();
        let indices = self.controls.list.multi_selection();
        self.controls.delete.set_enabled(false);
        self.controls.action.set_enabled(false);
        let detail = match &*items {
            Items::Caches(review) => {
                let selected: Vec<_> = indices
                    .iter()
                    .filter_map(|index| review.candidates.get(*index))
                    .collect();
                let total = selected
                    .iter()
                    .filter(|item| item.blocked.is_none())
                    .map(|item| item.bytes)
                    .fold(0u64, u64::saturating_add);
                self.controls
                    .action
                    .set_enabled(selected.iter().any(|item| item.blocked.is_none()));
                let mut lines = vec![format!(
                    "{} selected · {} ready to move",
                    selected.len(),
                    size_label(total)
                )];
                lines.extend(selected.iter().map(|item| {
                    item.blocked
                        .clone()
                        .unwrap_or_else(|| item.path.display().to_string())
                }));
                lines.extend(review.skipped.iter().cloned());
                lines.join("\r\n")
            }
            Items::Recovery(items) => {
                let selected: Vec<_> = indices
                    .iter()
                    .filter_map(|index| items.get(*index))
                    .collect();
                self.controls.action.set_enabled(
                    !selected.is_empty() && selected.iter().all(|item| !item.deleting),
                );
                self.controls.delete.set_enabled(!selected.is_empty());
                selected
                    .first()
                    .map(|item| item.path.display().to_string())
                    .unwrap_or_default()
            }
            Items::History(history) => {
                let receipt = indices
                    .first()
                    .and_then(|index| history.get(*index))
                    .map(|(_, receipt)| receipt);
                self.controls
                    .action
                    .set_enabled(receipt.is_some_and(|receipt| !receipt.copies.is_empty()));
                receipt
                    .map(|receipt| receipt.details.join("\r\n"))
                    .unwrap_or_default()
            }
        };
        self.controls.detail.set_text(&detail);
    }

    fn confirm(&self, title: &str, content: &str) -> bool {
        nwg::modal_message(
            &self.controls.window,
            &nwg::MessageParams {
                title,
                content,
                buttons: nwg::MessageButtons::OkCancel,
                icons: nwg::MessageIcons::Question,
            },
        ) == nwg::MessageChoice::Ok
    }

    fn apply(&self, delete: bool) {
        let indices = self.controls.list.multi_selection();
        if indices.is_empty() {
            return;
        }
        match &*self.items.borrow() {
            Items::Caches(review) => {
                let selected: Vec<_> = indices
                    .iter()
                    .filter_map(|index| review.candidates.get(*index))
                    .cloned()
                    .collect();
                let count = selected
                    .iter()
                    .filter(|item| item.blocked.is_none())
                    .count();
                let mut details = review.skipped.clone();
                if count == 0 || !self.confirm(
                    "Move caches to recovery?",
                    &format!("Move {count} ready cache folders to recovery? The copies still use disk space."),
                ) { return; }
                self.work("Rechecking selected caches…", move |roots| {
                    let mut copies = Vec::new();
                    for item in selected {
                        let result = if let Some(reason) = &item.blocked {
                            Err(io::Error::other(reason.clone()))
                        } else {
                            cache::move_to_recovery(&roots, &item)
                        };
                        details.push(match result {
                            Ok(record) => {
                                copies.push(
                                    record
                                        .file_name()
                                        .unwrap_or_default()
                                        .to_string_lossy()
                                        .into_owned(),
                                );
                                format!("Moved {} to recovery.", cache_label(&item))
                            }
                            Err(error) => format!("Skipped {}: {error}", item.label()),
                        });
                    }
                    let moved = copies.len();
                    let receipt = save_summary(
                        &roots,
                        format!("{moved} moved · {} skipped", details.len() - moved),
                        details,
                        copies,
                    );
                    Update {
                        items: Ok(Items::Caches(cache::preview(&roots))),
                        receipt: Some(receipt),
                        select_copies: Vec::new(),
                    }
                });
            }
            Items::Recovery(items) => {
                let selected: Vec<_> = indices
                    .iter()
                    .filter_map(|index| items.get(*index))
                    .cloned()
                    .collect();
                let (question, detail) = if delete {
                    (
                        "Permanently delete selected copies?",
                        "The selected recovery copies cannot be restored after deletion.",
                    )
                } else {
                    (
                        "Restore selected caches?",
                        "Quit the apps before restoring. Existing caches will be preserved.",
                    )
                };
                if selected.is_empty() || !self.confirm(question, detail) {
                    return;
                }
                self.work(
                    if delete {
                        "Deleting selected copies…"
                    } else {
                        "Restoring selected caches…"
                    },
                    move |roots| {
                        let before = cache::free_space(&roots);
                        let mut done = 0;
                        let details = selected
                            .iter()
                            .map(|item| {
                                let result = if delete {
                                    cache::delete_recovery(&roots, item)
                                } else {
                                    cache::restore(&roots, item)
                                };
                                match result {
                                    Ok(()) => {
                                        done += 1;
                                        format!(
                                            "{} {}.",
                                            if delete { "Deleted" } else { "Restored" },
                                            item.label()
                                        )
                                    }
                                    Err(error) => format!("Skipped {}: {error}", item.label()),
                                }
                            })
                            .collect::<Vec<_>>();
                        let mut summary = format!(
                            "{done} {} · {} skipped",
                            if delete { "deleted" } else { "restored" },
                            details.len() - done
                        );
                        if let (true, Some(before), Some(after)) =
                            (delete, before, cache::free_space(&roots))
                        {
                            summary.push_str(&format!(
                                " · Volume free space {}{}",
                                if after >= before { "+" } else { "−" },
                                size_label(after.abs_diff(before))
                            ));
                        }
                        let receipt = save_summary(&roots, summary, details, Vec::new());
                        Update {
                            items: cache::recovery_items(&roots).map(Items::Recovery),
                            receipt: Some(receipt),
                            select_copies: Vec::new(),
                        }
                    },
                );
            }
            Items::History(receipts) => {
                let Some((_, receipt)) = indices.first().and_then(|index| receipts.get(*index))
                else {
                    return;
                };
                let ids = receipt.copies.clone();
                self.work("Finding the recovery copies…", move |roots| {
                    let items = cache::recovery_items(&roots);
                    let found = items
                        .as_ref()
                        .is_ok_and(|items| items.iter().any(|item| ids.contains(&item.id())));
                    Update {
                        items: items.map(Items::Recovery),
                        receipt: if found {
                            None
                        } else {
                            Some("The copies from this run are no longer in recovery.".into())
                        },
                        select_copies: ids,
                    }
                });
            }
        }
    }
}

fn receipt_age(name: &str) -> String {
    use std::time::{Duration, SystemTime, UNIX_EPOCH};
    let Some(nanos) = name
        .split('-')
        .next()
        .and_then(|prefix| prefix.parse::<u128>().ok())
    else {
        return "Date unavailable".into();
    };
    let seconds = nanos / 1_000_000_000;
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_secs() as u128;
    let minutes = elapsed.saturating_sub(seconds) / 60;
    match minutes {
        0 => "Just now".into(),
        1..=59 => format!("{minutes} min ago"),
        60..=1439 => format!("{} hr ago", minutes / 60),
        _ => format!("{} days ago", minutes / 1440),
    }
}

fn save_summary(roots: &Roots, title: String, details: Vec<String>, copies: Vec<String>) -> String {
    let receipt = cache::Receipt {
        title,
        details,
        copies,
    };
    match cache::save_receipt(roots, &receipt) {
        Ok(()) => receipt.title,
        Err(error) => format!("{}. Couldn’t save history: {error}", receipt.title),
    }
}

fn cache_label(item: &Candidate) -> String {
    format!(
        "{} · {}{}",
        item.label(),
        size_label(item.bytes),
        if item.blocked.is_some() {
            " · Quit app, then rescan"
        } else {
            ""
        }
    )
}

fn size_label(bytes: u64) -> String {
    if bytes >= 1_048_576 {
        format!("{:.1} MiB", bytes as f64 / 1_048_576.0)
    } else if bytes >= 1024 {
        format!("{:.1} KiB", bytes as f64 / 1024.0)
    } else {
        format!("{bytes} B")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{Duration, Instant};

    #[test]
    fn native_window_shows_cache_preview() -> Result<(), Box<dyn std::error::Error>> {
        let fixture = tempfile::tempdir()?;
        let cache = fixture
            .path()
            .join(r"Local\Google\Chrome\User Data\Default\Cache");
        let roaming = fixture.path().join("Roaming");
        fs::create_dir_all(&cache)?;
        fs::create_dir(&roaming)?;
        fs::write(cache.join("example"), b"test cache")?;
        let second = cache.with_file_name("GPUCache");
        fs::create_dir(&second)?;
        fs::write(second.join("example"), b"other")?;

        let desktop = build_window(Roots {
            local: fixture.path().join("Local"),
            roaming,
        })?;
        let handler = bind_events(&desktop);
        desktop.scan();

        let active = Rc::clone(&desktop);
        let deadline = Instant::now() + Duration::from_secs(5);
        nwg::dispatch_thread_events_with_callback(move || {
            if active.controls.scan.enabled() || Instant::now() >= deadline {
                nwg::stop_thread_dispatch();
            } else {
                std::thread::sleep(Duration::from_millis(10));
            }
        });
        nwg::unbind_event_handler(&handler);

        assert_eq!(desktop.controls.window.text(), "Diskfolio");
        assert_eq!(
            desktop.controls.list.collection().as_slice(),
            &[
                "Chrome · Default / Cache · 10 B",
                "Chrome · Default / GPUCache · 5 B"
            ]
        );
        assert!(!desktop.controls.action.enabled());
        desktop.controls.list.multi_add_selection(0);
        desktop.controls.list.multi_add_selection(1);
        desktop.select();
        assert!(desktop.controls.action.enabled());
        assert!(
            desktop
                .controls
                .detail
                .text()
                .contains("2 selected · 15 B ready to move")
        );
        assert_eq!(fs::read(cache.join("example"))?, b"test cache");
        Ok(())
    }
}
