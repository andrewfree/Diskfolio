use crate::cache::{self, Candidate, Recovery, Roots};
use native_windows_gui as nwg;
use std::cell::RefCell;
use std::io;
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver, Sender};

enum Items {
    Caches(cache::Review),
    Recovery(Vec<Recovery>),
}

struct Update {
    items: io::Result<Items>,
    receipt: Option<String>,
}

#[derive(Default)]
struct Controls {
    window: nwg::Window,
    heading: nwg::Label,
    status: nwg::Label,
    list: nwg::ListBox<String>,
    detail: nwg::Label,
    scan: nwg::Button,
    recovery: nwg::Button,
    action: nwg::Button,
    reveal: nwg::Button,
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
        .flags(nwg::ListBoxFlags::VISIBLE | nwg::ListBoxFlags::TAB_STOP)
        .position((22, 104))
        .size((635, 193))
        .parent(window)
        .build(&mut controls.list)?;
    nwg::Label::builder()
        .position((22, 308))
        .size((635, 58))
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
        .text("Open recovery folder")
        .position((266, 380))
        .size((176, 33))
        .parent(window)
        .build(&mut controls.reveal)?;
    nwg::Notice::builder()
        .parent(window)
        .build(&mut controls.notice)?;

    controls.reveal.set_visible(false);
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
            nwg::Event::OnButtonClick if handle == app.controls.action.handle => app.apply(),
            nwg::Event::OnButtonClick if handle == app.controls.reveal.handle => app.reveal(),
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
        self.controls.reveal.set_enabled(false);
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
        });
    }

    fn recoveries(&self) {
        self.work("Reading recovery records…", |roots| Update {
            items: cache::recovery_items(&roots).map(Items::Recovery),
            receipt: None,
        });
    }

    fn finish(&self) {
        let Ok(update) = self.rx.try_recv() else {
            return;
        };
        self.controls.list.set_enabled(true);
        self.controls.scan.set_enabled(true);
        self.controls.recovery.set_enabled(true);
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
                    review.skipped
                ),
                review.candidates.iter().map(cache_label).collect(),
            ),
            Items::Recovery(items) => (
                "Recovery",
                "Restore selected cache",
                format!(
                    "{} folders in recovery. Select a cache to restore it.",
                    items.len()
                ),
                items.iter().map(Recovery::label).collect(),
            ),
        };
        self.controls
            .reveal
            .set_visible(matches!(&items, Items::Recovery(_)));
        self.controls
            .reveal
            .set_enabled(matches!(&items, Items::Recovery(items) if !items.is_empty()));
        self.controls.heading.set_text(heading);
        self.controls.action.set_text(action);
        self.controls.status.set_text(&match update.receipt {
            Some(receipt) => format!("{receipt}\r\n{status}"),
            None => status,
        });
        self.controls.list.set_collection(labels);
        self.items.replace(items);
        self.select();
    }

    fn reveal(&self) {
        if let Err(error) = std::process::Command::new("explorer.exe")
            .arg(self.roots.recovery())
            .spawn()
        {
            self.controls.status.set_text(&error.to_string());
        }
    }

    fn select(&self) {
        let items = self.items.borrow();
        let Some(index) = self.controls.list.selection() else {
            self.controls.detail.set_text("");
            self.controls.action.set_enabled(false);
            return;
        };
        let path = match &*items {
            Items::Caches(review) => review.candidates.get(index).map(|item| &item.path),
            Items::Recovery(items) => items.get(index).map(|item| &item.path),
        };
        self.controls.action.set_enabled(path.is_some());
        if let Some(path) = path {
            self.controls.detail.set_text(&path.to_string_lossy());
        }
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

    fn apply(&self) {
        let Some(index) = self.controls.list.selection() else {
            return;
        };
        match &*self.items.borrow() {
            Items::Caches(review) => {
                let Some(item) = review.candidates.get(index).cloned() else {
                    return;
                };
                let detail = format!(
                    "{}\r\n{}\r\n\r\nThe files will still use disk space while they are in recovery.",
                    cache_label(&item),
                    item.path.display()
                );
                if self.confirm("Move cache to recovery?", &detail) {
                    self.work("Rechecking the selected cache…", move |roots| {
                        let receipt = cache::move_to_recovery(&roots, &item)
                            .map(|()| "Cache moved to recovery.".to_owned())
                            .unwrap_or_else(|error| format!("Cache skipped. {error}"));
                        Update {
                            items: Ok(Items::Caches(cache::preview(&roots))),
                            receipt: Some(receipt),
                        }
                    });
                }
            }
            Items::Recovery(items) => {
                let Some(item) = items.get(index).cloned() else {
                    return;
                };
                if self.confirm("Restore selected cache?", &item.path.to_string_lossy()) {
                    self.work("Restoring the selected cache…", move |roots| {
                        let receipt = cache::restore(&roots, &item)
                            .map(|()| "Cache restored.".to_owned())
                            .unwrap_or_else(|error| format!("Restore skipped. {error}"));
                        Update {
                            items: cache::recovery_items(&roots).map(Items::Recovery),
                            receipt: Some(receipt),
                        }
                    });
                }
            }
        }
    }
}

fn cache_label(item: &Candidate) -> String {
    let bytes = item.bytes;
    let size = if bytes >= 1_048_576 {
        format!("{:.1} MiB", bytes as f64 / 1_048_576.0)
    } else if bytes >= 1024 {
        format!("{:.1} KiB", bytes as f64 / 1024.0)
    } else {
        format!("{bytes} B")
    };
    format!("{} · {size}", item.label())
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
            &["Chrome · Default / Cache · 10 B"]
        );
        assert!(!desktop.controls.action.enabled());
        assert_eq!(fs::read(cache.join("example"))?, b"test cache");
        Ok(())
    }
}
