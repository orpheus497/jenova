use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tauri::{
    menu::{MenuBuilder, MenuItemBuilder},
    tray::{TrayIconBuilder, TrayIconEvent},
    Manager,
};
use tauri_plugin_shell::ShellExt;

struct AppState {
    lan_mode: AtomicBool,
}

fn get_jenova_ca_path() -> String {
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(bin_dir) = exe_path.parent() {
            return bin_dir.join("jenova-ca").to_string_lossy().into_owned();
        }
    }
    "jenova-ca".to_string()
}

#[tauri::command]
async fn start_backend(app: tauri::AppHandle) -> Result<String, String> {
    let state = app.state::<Arc<AppState>>();
    let ca_path = get_jenova_ca_path();
    let mut args = vec![ca_path.clone(), "start".to_string()];
    if state.lan_mode.load(Ordering::SeqCst) {
        args.push("--lan".to_string());
    }
    
    let shell = app.shell();
    let output = shell.command("bash").args(&args).output().await.map_err(|e| e.to_string())?;
    
    if output.status.success() { Ok("Backend started".into()) } else { Err(String::from_utf8_lossy(&output.stderr).into()) }
}

#[tauri::command]
async fn stop_backend(app: tauri::AppHandle) -> Result<String, String> {
    let shell = app.shell();
    let output = shell.command("bash").args([get_jenova_ca_path(), "stop".to_string()]).output().await.map_err(|e| e.to_string())?;
    if output.status.success() { Ok("Backend stopped".into()) } else { Err(String::from_utf8_lossy(&output.stderr).into()) }
}

#[tauri::command]
async fn get_backend_status(app: tauri::AppHandle) -> Result<String, String> {
    let shell = app.shell();
    let output = shell.command("bash").args([get_jenova_ca_path(), "status".to_string()]).output().await.map_err(|e| e.to_string())?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    if stdout.contains("running") { Ok("running".into()) } else { Ok("stopped".into()) }
}

async fn check_status_and_update_tray(app: tauri::AppHandle) {
    let shell = app.shell();
    let output = shell.command("bash").args([get_jenova_ca_path(), "status".to_string()]).output().await;

    let is_running = output.map(|out| String::from_utf8_lossy(&out.stdout).contains("running")).unwrap_or(false);
    
    let state = app.state::<Arc<AppState>>();
    let is_lan = state.lan_mode.load(Ordering::SeqCst);
    
    if let Some(tray) = app.tray_by_id("main") {
        let tooltip = if is_running {
            if is_lan { "Jenova (Active - LAN Mode)" } else { "Jenova (Active - Local Mode)" }
        } else {
            "Jenova (Inactive)"
        };
        let _ = tray.set_tooltip(Some(tooltip));
        
        let icon_bytes = if is_running {
            include_bytes!("../icons/tray.png").to_vec()
        } else {
            include_bytes!("../icons/tray-bw.png").to_vec()
        };
        
        if let Ok(icon) = tauri::image::Image::from_bytes(&icon_bytes) {
            let _ = tray.set_icon(Some(icon));
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app_state = Arc::new(AppState {
        lan_mode: AtomicBool::new(false),
    });

    tauri::Builder::default()
        .manage(app_state.clone())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
            }
        }))
        .setup(|app| {
            let show = MenuItemBuilder::with_id("show", "Show Jenova").build(app)?;
            let start = MenuItemBuilder::with_id("start", "Start Server").build(app)?;
            let stop = MenuItemBuilder::with_id("stop", "Stop Server").build(app)?;
            let reset = MenuItemBuilder::with_id("reset", "Reset Server").build(app)?;
            let toggle_lan = MenuItemBuilder::with_id("toggle_lan", "Switch LAN/LOCAL").build(app)?;
            let quit = MenuItemBuilder::with_id("quit", "Quit").build(app)?;
            
            let menu = MenuBuilder::new(app)
                .items(&[&show, &start, &stop, &reset, &toggle_lan, &quit])
                .build()?;

            let initial_icon = tauri::image::Image::from_bytes(include_bytes!("../icons/tray-bw.png")).ok()
                .or_else(|| app.default_window_icon().cloned());
                
            if let Some(icon) = initial_icon {
                let _tray = TrayIconBuilder::with_id("main")
                    .icon(icon)
                    .menu(&menu)
                    .tooltip("Jenova (Inactive)")
                    .on_menu_event(|app, event| match event.id.as_ref() {
                        "quit" => { app.exit(0); }
                        "show" => {
                            if let Some(window) = app.get_webview_window("main") {
                                let _ = window.show();
                                let _ = window.set_focus();
                            }
                        }
                        "start" => {
                            let app_clone = app.clone();
                            tauri::async_runtime::spawn(async move { let _ = start_backend(app_clone).await; });
                        }
                        "stop" => {
                            let app_clone = app.clone();
                            tauri::async_runtime::spawn(async move { let _ = stop_backend(app_clone).await; });
                        }
                        "reset" => {
                            let app_clone = app.clone();
                            tauri::async_runtime::spawn(async move {
                                let _ = stop_backend(app_clone.clone()).await;
                                std::thread::sleep(std::time::Duration::from_secs(2));
                                let _ = start_backend(app_clone).await;
                            });
                        }
                        "toggle_lan" => {
                            let state = app.state::<Arc<AppState>>();
                            let current = state.lan_mode.load(Ordering::SeqCst);
                            state.lan_mode.store(!current, Ordering::SeqCst);
                            
                            let app_clone = app.clone();
                            tauri::async_runtime::spawn(async move {
                                let _ = stop_backend(app_clone.clone()).await;
                                std::thread::sleep(std::time::Duration::from_secs(2));
                                let _ = start_backend(app_clone).await;
                            });
                        }
                        _ => {}
                    })
                    .on_tray_icon_event(|tray, event| {
                        if let TrayIconEvent::Click { .. } = event {
                            if let Some(window) = tray.app_handle().get_webview_window("main") {
                                let _ = window.show();
                                let _ = window.set_focus();
                            }
                        }
                    })
                    .build(app);
            }

            // Start background status poller
            let app_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    check_status_and_update_tray(app_handle.clone()).await;
                    tokio::time::sleep(tokio::time::Duration::from_secs(3)).await;
                }
            });

            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                window.hide().unwrap();
                api.prevent_close();
            }
        })
        .invoke_handler(tauri::generate_handler![
            start_backend,
            stop_backend,
            get_backend_status
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

