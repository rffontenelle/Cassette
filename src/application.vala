/* Copyright 2023-2024 Rirusha
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, version 3
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

using Cassette.Client;


namespace Cassette {

    static Authenticator authenticator;

    public static Application application;
    public static Cassette.Client.Cachier.Cachier cachier;
    public static Cassette.Client.Cachier.Storager storager;
    public static Cassette.Client.Threader threader;
    public static Cassette.Client.YaMTalker yam_talker;
    public static Cassette.Client.Player.Player player;

    public static Settings settings;

    public enum ApplicationState {
        BEGIN,
        LOCAL,
        ONLINE,
        OFFLINE
    }

    public class Application : Adw.Application {

        const ActionEntry[] ACTION_ENTRIES = {
            { "quit", quit },
            { "log-out", on_log_out },
            { "play-pause", on_play_pause_action },
            { "next", on_next_action },
            { "prev", on_prev_action },
            { "prev-force", on_prev_force_action },
            { "change-shuffle", on_change_shuffle_action },
            { "change-repeat", on_change_repeat_action },
            { "share-current-track", on_share_current_track_action},
            { "parse-url", on_parse_url_action }
        };

        ApplicationState _application_state;
        public ApplicationState application_state {
            get {
                return _application_state;
            }
            set {
                if (_application_state == value) {
                    return;
                }

                var old_state = _application_state;

                _application_state = value;

                // Don't write "Connection restored" after auth
                if (old_state != ApplicationState.BEGIN) {
                    application_state_changed (_application_state);
                }
            }
        }

        public signal void application_state_changed (ApplicationState new_state);

        public Window? main_window { get; private set; default = null; }

        uint now_playing_t = 0;

        public bool is_devel {
            get {
                return Config.PROFILE == "Devel";
            }
        }

        public Application () {
            Object (
                application_id: Config.APP_ID_DYN,
                resource_base_path: "/io/github/Rirusha/Cassette/"
            );
        }

        construct {
            application = this;

            settings = new Settings ("io.github.Rirusha.Cassette.application");

            Cassette.Client.init (is_devel);

            Cassette.Client.Mpris.mpris.quit_triggered.connect (() => {
                quit ();
            });
            Cassette.Client.Mpris.mpris.raise_triggered.connect (() => {
                main_window.present ();
            });

            // Shortcuts
            cachier = Cassette.Client.cachier;
            storager = Cassette.Client.storager;
            threader = Cassette.Client.threader;
            authenticator = new Authenticator ();
            yam_talker = Cassette.Client.yam_talker;
            player = Cassette.Client.player;

            yam_talker.connection_established.connect (() => {
                application_state = ApplicationState.ONLINE;
            });
            yam_talker.connection_lost.connect (() => {
                application_state = ApplicationState.OFFLINE;
            });

            player.current_track_finish_loading.connect (show_now_playing_notif);

            _application_state = (ApplicationState) settings.get_enum ("application-state");

            settings.bind ("application-state", this, "application-state", SettingsBindFlags.DEFAULT);

            application.application_state_changed.connect ((new_state) => {
                switch (new_state) {
                    case ApplicationState.ONLINE:
                        show_message (_("Connection restored"));
                        main_window?.set_online ();
                        break;
                    case ApplicationState.OFFLINE:
                        show_message (_("Connection problems"));
                        main_window?.set_offline ();
                        break;
                    default:
                        break;
                }
            });

            add_action_entries (ACTION_ENTRIES, this);
            set_accels_for_action ("app.quit", { "<primary>q" });
            set_accels_for_action ("app.play-pause", { "space" });
            set_accels_for_action ("app.prev", { "<Ctrl>a" });
            set_accels_for_action ("app.next", { "<Ctrl>d" });
            set_accels_for_action ("app.change-shuffle", { "<Ctrl>s" });
            set_accels_for_action ("app.change-repeat", { "<Ctrl>r" });
            set_accels_for_action ("app.share-current-track", { "<Ctrl><Shift>c" });
            set_accels_for_action ("app.parse-url", { "<Ctrl><Shift>v" });
        }

        public override void activate () {
            base.activate ();

            if (main_window == null) {
                main_window = new Window (this);

                authenticator.success.connect (main_window.load_default_views);
                authenticator.local.connect (main_window.load_local_views);

                if (_application_state == ApplicationState.OFFLINE) {
                    _application_state = ApplicationState.ONLINE;
                }

                main_window.close_request.connect (() => {
                    main_window = null;
                    return false;
                });

                main_window.present ();

                if (_application_state == ApplicationState.LOCAL) {
                    main_window.load_local_views ();
                } else {
                    authenticator.log_in ();
                }

            } else {
                main_window.present ();
            }
        }

        public void show_message (string message) {
            if (main_window != null) {
                if (main_window.is_active) {
                    main_window.show_toast (message);
                    return;
                }
            }

            var ntf = new Notification (Config.APP_NAME);
            ntf.set_body (message);
            send_notification (null, ntf);
        }

        public void show_now_playing_notif (YaMAPI.Track track_info) {
            if (!settings.get_boolean ("show-playing-track-notif")) {
                return;
            }

            if (main_window != null) {
                if (main_window.is_active) {
                    return;
                }
            }

            var ntf = new Notification (Config.APP_NAME);

            ntf.set_body ("%s%s - %s".printf (
                track_info.title,
                track_info.version != null ? @" $(track_info.version)" : "",
                track_info.get_artists_names ()
            ));

            ntf.set_title (_("Now playing"));

            ntf.add_button (_("Previous"), "app.prev-force");
            ntf.add_button (_("Next"), "app.next");

            ntf.set_icon (new ThemedIcon ("%s-symbolic".printf (Config.APP_ID_DYN)));

            if (now_playing_t != 0) {
                Source.remove (now_playing_t);
            }

            send_notification ("now-playing", ntf);

            now_playing_t = Timeout.add_seconds_once (10, () => {
                withdraw_notification ("now-playing");
                now_playing_t = 0;
            });
        }

        void on_log_out () {
            authenticator.log_out ();
        }

        void on_play_pause_action () {
            var text_entry = main_window.focus_widget as Gtk.Text;
            if (text_entry != null) {
                // Исправление ситуации, когда пробел нельзя вписать, так как клавиша забрана play-pause
                text_entry.insert_at_cursor (" ");
            } else {
                player.play_pause ();
            }
        }

        void on_change_shuffle_action () {
            roll_shuffle_mode ();
        }

        void on_change_repeat_action () {
            roll_repeat_mode ();
        }

        void on_next_action () {
            if (player.can_go_next) {
                player.next ();
            }
        }

        void on_prev_action () {
            if (player.can_go_prev) {
                player.prev ();
            }
        }

        void on_prev_force_action () {
            if (player.can_go_prev) {
                player.prev (true);
            }
        }

        void on_share_current_track_action () {
            var current_track = player.mode.get_current_track_info ();

            if (current_track?.is_ugc == false) {
                track_share (current_track);
            }
        }

        void on_parse_url_action () {
            activate ();

            Gdk.Display? display = Gdk.Display.get_default ();
            Gdk.Clipboard clipboard = display.get_clipboard ();

            clipboard.read_text_async.begin (null, (obj, res) => {
                try {
                    string url = clipboard.read_text_async.end (res);

                    if (!url.has_prefix ("https://music.yandex.ru/")) {
                        show_message (_("Can't parse clipboard content"));
                        return;
                    }

                    string[] parts = url.split ("/");

                    // Cut https://music.yandex.ru
                    parts = parts [3:parts.length];

                    // users 737063213
                    if (parts[0] == "users") {
                        string user_id = parts[1];

                        // playlists ~
                        if (parts[2] == "playlists") {
                            if (parts.length == 3) {
                                show_message (_("Users view not implemented yet"));
                                return;

                            // playlists 3
                            } else {
                                string kind = parts[3];

                                main_window?.current_view.add_view (new PlaylistView (user_id, kind));
                            }
                        }

                    // album 4545465
                    } else if (parts[0] == "album") {
                        // string album_id = parts[1];

                        if (parts.length == 2) {
                            show_message (_("Albums view not implemented yet"));

                        // album 87894564 track 54654
                        } else {
                            string track_id;

                            if ("?" in parts[3]) {
                                track_id = parts[3].split ("?")[0];
                            } else {
                                track_id = parts[3];
                            }

                            show_track_by_id.begin (track_id);

                            show_message (_("Albums view not implemented yet"));
                        }
                    }

                } catch (Error e) {
                    show_message (_("Can't parse clipboard content"));
                }
            });
        }
    }
}
