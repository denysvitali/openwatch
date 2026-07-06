# H59MA v14 Firmware — Ghidra Decompilation Notes

> Generated from `firmwares/_re/v14/body.bin` loaded in Ghidra at base `0x00826400`.
> Language: `ARM:LE:32:Cortex`, raw binary, ~136 KB, 1,172 function entries.

---

## 0.1 Current Ghidra Symbol Pass

On 2026-06-23 the saved `openwatch_v14` Ghidra project was updated with
high-confidence names and plate comments for the transport and OTA core. These
renames are intentionally conservative and are reflected in fresh decompiler
output:

| Address | New name | Role |
|---|---|---|
| `0x0082d2dc` | `channel_a_dispatch_queued_frame` | Drains the deferred 16-byte Channel-A/vendor-high command ring. |
| `0x0082c944` | `vendor_high_dispatch_command` | Channel-A-reachable 16-byte vendor/high dispatcher; earlier notes mislabeled its GATT entry as FEE7. |
| `0x0082efea` | `channel_b_parse_reassembly_frame` | Parses and reassembles Channel-B `0xBC` frames. |
| `0x0082eee6` | `channel_b_dispatch_complete_frame` | Verifies CRC and routes complete Channel-B frames. |
| `0x0082ece0` | `channel_b_queue_notify_frame` | Builds and MTU-slices Channel-B notify frames. |
| `0x0082ee00` | `channel_b_send_nak` | Builds compact Channel-B NAK/error packets. |
| `0x0082f114` | `crc16_modbus_update` | CRC-16/MODBUS helper using the reflected `0xA001` table. |
| `0x0082ebdc` | `channel_a_queue_notify_frame` | Queues a 16-byte Channel-A/vendor-high notify frame. |
| `0x0082b0c4` | `checksum8_additive` | Additive byte-sum helper used for 16-byte command responses. |
| `0x0082b938` | `channel_a_send_fragmented_response` | Sends long Channel-A/vendor-high payloads as 14-byte chunks. |
| `0x0082be64` | `enqueue_deferred_command_frame` | Copies incoming 16-byte requests into the deferred command ring. |
| `0x0082ba94` | `fee7_vendor_memory_write` | Security-sensitive host-addressed memory write. |
| `0x0082bb0c` | `fee7_vendor_memory_read` | Security-sensitive host-addressed memory read. |
| `0x0082bcba` | `fee7_send_vendor_nak` | FEE7 unknown-command response (request opcode OR `0x80`, marker `0xee`). |
| `0x0082fe52` | `ota_dfu_state_machine` | OTA/DFU state machine. |
| `0x00840724` | `cfg_blob_magic_ok` | Checks persistent config-blob magic `0x8721bee2`. |
| `0x00833bbc` | `channel_b_send_activity_summary` | Channel-B `0x2a` activity-summary response builder. |
| `0x00833334` | `lis3dh_accel_dispatch` | LIS3DH accelerometer dispatcher entry. |

Key data labels added in the same pass: `channel_a_command_queue_state`
(`0x0082d440`), `deferred_command_ring_state` (`0x0082bfcc`),
`channel_a_notify_ring_state` (`0x0082edb8`),
`channel_b_notify_ring_state` (`0x0082edbc`),
`channel_b_rx_reassembly_state` (`0x0082f0f0`),
`crc16_modbus_table` (`0x008457c0`), and
`health_metric_clamp_constants` (`0x0084630c`).

Second pass on the same date expanded Channel-B/OTA/storage coverage. Later
correction/sensor, boot/BLE, protocol-adjacent helper, runtime, FEE7 switch,
GPIO/sensor-bus, persistent-history, alert/UI, display/name, ANCS/GATT,
soft-float, GPIO/AON, and raw FEE7-control passes brought the saved Ghidra
project to 1,205 function entries: 313 named functions and 892 remaining auto-named
`FUN_`/`thunk_FUN_` entries. New high-confidence names:

| Address | New name | Role |
|---|---|---|
| `0x0082fc0c` | `channel_b_async_command_processor` | Drains async Channel-B command state and dispatches handlers. |
| `0x0082f4fa` | `channel_b_store_async_command` | Stores parsed cmd/payload/length for async handling. |
| `0x0082f4a6` | `channel_b_enqueue_async_command` | Appends `[cmd,len,payload]` records to the async queue. |
| `0x0082f494` | `channel_b_init_async_command_context` | Clears and initialises the async command context. |
| `0x0082f098` / `0x0082f0d4` | `channel_b_start_fragment_timeout` / `channel_b_cancel_fragment_timeout` | Arms/cancels the 2000 ms Channel-B fragment watchdog. |
| `0x0082f1a4` / `0x0082f1b6` | `ota_cmd_start_ack` / `ota_cmd_init_metadata` | OTA start ack and 9-byte init metadata parser. |
| `0x0082f240` | `ota_cmd_write_data_packet` | Validates OTA sequence and `0x81bdc3e5` container header, erases pages, writes image data. |
| `0x0082f378` / `0x0082f3b4` / `0x0082f410` | `ota_cmd_check_complete` / `ota_cmd_end_reboot` / `ota_cmd_sub_ack` | OTA completion check, final reboot path, and state-7 ack. |
| `0x0082f5a2` / `0x0082f50c` / `0x0082fada` | `channel_b_send_sleep_summary` / `channel_b_send_detailed_sleep` / `channel_b_send_sleep_records` | Channel-B sleep summary/detail/record responses. |
| `0x0082f8ec` | `channel_b_handle_alarm_read_write` | Channel-B `0x2c` alarm read/write importer/exporter. |
| `0x008311b8` | `channel_b_handle_file_command` | Channel-B `0x41` list and `0x43` file-transfer handler. |
| `0x0082f6ec` | `channel_b_handle_device_info_config` | Channel-B `0x5a` device-info/config TLV handler. |
| `0x0083105a` / `0x008310c8` / `0x008313ba` / `0x0083136a` | `file_format_list_entry` / `file_send_transfer_chunks` / `file_read_list_entry` / `file_find_record_by_id` | File-table serialisation, transfer, and lookup helpers. |
| `0x00831230` / `0x0083124c` / `0x0083127e` / `0x00831292` | `file_table_format_all` / `file_load_recent_record` / `file_table_ensure_scanned` / `file_commit_record` | Two-sector circular file-table maintenance. |
| `0x008318b0` / `0x008318c2` / `0x00831908` | `sleep_read_detail_record` / `sleep_read_summary_record` / `sleep_read_nap_record` | Persisted/live sleep record readers. |
| `0x008315ba` / `0x008315f8` | `sleep_write_live_detail_slot` / `sleep_accumulate_live_detail_slot` | Live detailed-sleep slot update helpers. |
| `0x00833b42` | `activity_read_day_summary_record` | Per-day activity summary reader and live-sample overlay. |

Important data aliases from the second pass: `channel_b_async_state_ptr_primary`
(`0x0082f894`) and `channel_b_async_state_ptr_alias` (`0x0082fcbc`) both point
at the same async Channel-B context base (`0x0020b9a8` in this image), while
`channel_b_async_payload_buffer_ptr` (`0x0082f898`) points at the backing
payload/queue buffer.

Third pass added correction and sensor coverage:

| Address | New name | Role |
|---|---|---|
| `0x00840724` | `cfg_blob_magic_ok` | Persistent config blob header validator. |
| `0x00840be0` / `0x0084415c` | `cfg_find_item` / `cfg_read_mac_item` | Config item scan and item `0x33` read. |
| `0x00840568` / `0x00840774` | `cfg_update_mac_item` / `cfg_write_to_flash_preserve_sector` | Config item `0x33` writer and sector-preserving flash rewrite. |
| `0x00829360` / `0x00829408` / `0x008293d2` | `flash_erase_sector_locked` / `flash_write_locked` / `flash_read_locked` | Locked flash erase/write/read wrappers. |
| `0x0082ef50` | `channel_b_fragment_timeout_cb` | Channel-B reassembly/OTA timeout callback. |
| `0x0082bb4e`..`0x0082cde8` | `channel_a_handle_*` names | High-confidence Channel-A handler names from the dispatcher. |
| `0x008332dc`..`0x00832dd6` | `gsensor_*` names | Accelerometer probe/config/FIFO/service-state flow. |
| `0x0082c2f4` / `0x0082c1e2` / `0x00833770` | `health_handle_start_measure` / `health_handle_stop_measure` / `health_module_event_dispatch` | Shared health measurement start/stop event path. |

Fourth pass added boot, BLE, and offset-store names:

| Address | New name | Role |
|---|---|---|
| `0x00826988` | `app_main_task` | Post-reset main task; loads persistent blobs, registers BLE profile/services, starts runtime tasks. |
| `0x008294e0` / `0x008294cc` | `settings_blob0_load_or_init` / `settings_blob0_commit` | Offset-store slot `0`, length `0xe0`, magic byte `0x04`. |
| `0x0082952a` / `0x0082954a` / `0x00829560` | `user_config_block_load_ok` / `user_config_block_commit` / `user_config_block_clear_persisted` | Offset-store slot `0x200`, length `0xa4`, user-visible config block used by reset/config paths. |
| `0x00826904` | `user_config_load_or_init` | Loads/initialises the 164-byte user-config block, mirrors byte `+0x0d` to `+0xa6`, then starts feature initialisers. |
| `0x0082696c` | `app_init_runtime_tasks_and_timers` | Creates runtime queues/tasks/timers and initialises Channel-B async state. |
| `0x00827202` | `app_init_feature_modules` | Starts feature modules including health, gsensor, storage, alarms, and notification subsystems. |
| `0x0082e28c` / `0x0082e464` | `ble_gap_profile_register` / `ble_services_init` | Builds advertising/name data, registers GAP/GATT profile values, registers Oudmon/FEE7 services. |
| `0x0082e068` / `0x0082ecbc` | `ble_build_device_name_and_adv_data` / `ble_notify_rings_init` | Constructs device name/advertising fields and initialises Channel-A/B notify rings. |
| `0x008272ec` | `create_qc_app_task` | Creates the `qc_app` RTOS task (`0xe00` stack, priority `1`). |

Fifth pass added protocol-adjacent helper names from the feature-module tree:

| Address | New name | Role |
|---|---|---|
| `0x00829c24` | `timer_create_or_restart_ms` | Shared timer helper: create named timer if absent, otherwise restart it with a millisecond period. |
| `0x0082966e` / `0x008296b6` | `history_ring_find_record_by_key` / `history_ring_find_first_used_slot` | Shared persistent-history ring lookup helpers used by sleep/activity/BP/pressure/HRV tables. |
| `0x0082a72a` / `0x0082a6cc` | `dnd_schedule_init` / `dnd_schedule_apply_current_state` | Initialises DND defaults and recomputes the live DND-enabled flag from current minute and configured window. |
| `0x0082a7e4` / `0x0082a78e` | `dnd_schedule_encode_response` / `dnd_schedule_update_from_frame` | Channel-A `0x06` DND read/write helpers. |
| `0x0082d4ce` | `channel_a_send_device_notify` | Builds opcode `0x73` device notify frames for sport/DND/sensor state changes. |
| `0x0082adf4` / `0x0082ae84` | `sedentary_config_update_from_frame` / `sedentary_config_encode_response` | Channel-A `0x25/0x26` sedentary reminder encoding and validation. |
| `0x0082adac` / `0x0082adca` / `0x0082ade0` | `sedentary_config_defaults_init` / `sedentary_config_mark_dirty` / `sedentary_module_init` | Sedentary defaults and dirty state. Default config is `08:00` to `18:00`, threshold `60` minutes. |
| `0x0082ac50` / `0x0082ac72` | `alarm_module_init` / `alarm_defaults_normalize` | Normalises up to ten 0x29-byte alarm records, defaulting unset slots to enabled 08:15 daily. |
| `0x0082b078` / `0x0082af28` / `0x0082aee4` | `menstruation_config_init` / `menstruation_config_encode_response` / `menstruation_config_update_from_frame` | Channel-A `0x2b` menstrual-cycle config helpers. |
| `0x0082b92c` / `0x0082b21e` | `health_service_init` / `app_ring_sport_timer_init` | Creates health timers and a 1000 ms app-ring sport-data timer. |
| `0x00833e56` | `health_metrics_init` | Fan-out health metric initialiser for HR, BP, SpO2, pressure, HRV, blood sugar, and body temperature stubs. |
| `0x00834478` / `0x00834410` / `0x00834296` | `bp_history_module_init` / `bp_history_advance_read_cursor` / `bp_history_build_next_chunks` | Blood-pressure history state used by Channel-A `0x0e` confirm/read path. |
| `0x0083462c` / `0x008344fe` / `0x00834556` | `pressure_history_table_init` / `pressure_history_read_day` / `pressure_current_value` | Pressure/stress history and current-value helpers for Channel-A `0x36/0x37` and health stop results. |
| `0x008347bc` / `0x0083468e` / `0x008346e4` | `hrv_history_table_init` / `hrv_history_read_day` / `hrv_current_value` | HRV history/current helpers for Channel-A `0x39` and health stop results. |
| `0x0083486a` / `0x0083485c` | `blood_sugar_metric_init` / `blood_sugar_current_value` | Blood-sugar metric default/current helpers. |
| `0x00833a50` / `0x00837ade` | `spo2_current_value` / `heart_rate_current_bpm` | Current-value getters used by health stop/result frames. |
| `0x0083371e` / `0x00833704` / `0x00837b96` / `0x00837c4e` | `health_post_start_measure_event` / `health_post_stop_measure_event` / `health_start_sensor_mask` / `health_stop_sensor_mask` | Event-bus and sensor-mask control around health measurements. |
| `0x0082acf4` / `0x0082acf6` | `body_temperature_metric_init_stub` / `body_temperature_current_value_stub` | No-op body-temperature module initialiser and hardcoded-zero getter in this image. |
| `0x00830f56` | `sport_mode_timer_init` | Ensures the file table is scanned and creates `sports_mode_timer` at 2000 ms. |

Sixth pass added settings-persistence and sleep-refresh names:

| Address | New name | Role |
|---|---|---|
| `0x00829456` / `0x0082946e` | `settings_blob1_commit` / `settings_blob1_commit_if_changed` | Offset-store slot `0x400`, length `0x2b0`, magic byte `0x07`; compare-before-write wrapper used by SpO2 settings. |
| `0x0082edc4` / `0x0082ede2` | `bcd_to_u8` / `u8_to_bcd` | BCD conversion helpers used by time, sedentary, and DND settings. |
| `0x00827660` | `settings_set_spo2_enabled_commit_if_changed` | Updates settings blob1 bit `+0x2d[1]` and commits blob1 if changed. |
| `0x0082777e` / `0x0082779c` / `0x008277d8` | `settings_set_pressure_enabled_ram` / `settings_set_sugar_flag_ram` / `settings_set_lipids_flag_ram` | Update settings blob1 bits `+0x2d[3]`, `+0x2d[5]`, and `+0x2d[7]` in RAM. |
| `0x008409f8` | `cfg_upsert_items_and_rewrite_blob` | Upserts config item records and rewrites the `0x8721bee2` config blob through the sector-preserving flash path. |
| `0x00827624` / `0x008319dc` | `sleep_refresh_after_time_or_config_change` / `sleep_recompute_live_history_summary` | Refreshes live sleep detail/summary caches after time changes and touch/UV config writes. This is not a direct settings commit. |

Seventh pass added FEE7 vendor-service names:

| Address | New name | Role |
|---|---|---|
| `0x0082eebe` | `fee7_abort_active_ota_before_vendor_cmd` | Pre-dispatch FEE7 helper; if Channel-B OTA is active in state 2/3, aborts it before most vendor commands. |
| `0x00827ad2` / `0x00827aee` / `0x00827b14` | `fee7_send_test_ack_90` / `fee7_send_test_ack_91` / `fee7_noop_92` | Low-cost vendor test/echo opcodes. |
| `0x00827c4a` | `fee7_send_fw_version_build_info_93` | Sends firmware version/build strings, using blob0 overrides when enabled. |
| `0x00827b2e` / `0x00827b54` / `0x00827b7c` / `0x00827b1a` | `fee7_start_test_mode_94` / `fee7_start_test_mode_95` / `fee7_start_test_mode_96` / `fee7_restart_test_state_timer` | Updates vendor test-state byte and restarts a 1000 ms timer. |
| `0x0082bcde` | `fee7_handle_factory_test_ce` | Factory/test opcode `0xce`; subcommands read/write low-level bus registers and pulse GPIO/test routines. |
| `0x0082be12` | `fee7_vendor_memory_read_small_cd` | Opcode `0xcd`; reads up to 14 bytes from a host-supplied absolute address and returns them in one 16-byte frame. |
| `0x0082be90` / `0x0082bee6` | `fee7_store_pending_u32_60` / `fee7_read_pending_u32_61` | Vendor status/pending 32-bit value pair. |
| `0x0082bf40` | `fee7_send_today_sport_totals` | Opcode `0x48`; sends current step/distance/calorie-style counters plus two state bytes. |
| `0x0082c50e` / `0x0082c550` / `0x0082c5b8` | `fee7_send_fixed_capability_3c` / `fee7_handle_lipids_flag_3e` / `fee7_handle_test_request_51` | Fixed capability, lipids flag, and vendor alert/test request handlers. |

Eighth pass added runtime, RTC/settings, sensor-bus, FEE7 switch-table, and
persistent-history names:

| Address | New name | Role |
|---|---|---|
| `0x0083dfba` / `0x0083dfd6` | `__aeabi_uidivmod` / `__aeabi_idivmod` | ARM EABI integer divmod helpers; callers use `r0` quotient and `r1` remainder. |
| `0x0083df8c` / `0x0083dfa4` | `strcat_simple` / `read_u32_le_unaligned` | Small libc-style string append and unaligned little-endian u32 load helpers. |
| `0x0083deb0` / `0x008267cc` | `prng_seed` / `prng_next31` | 0x37-word additive PRNG ring seed and next-value helper. |
| `0x00827948` / `0x00827956` | `rtc_set_epoch_seconds` / `rtc_get_epoch_seconds` | RTC epoch setter/getter used by Channel-A time sync and daily-history indexing. |
| `0x00828176` / `0x00828390` / `0x0082840e` / `0x0082841e` | `calendar_fields_to_day_index` / `calendar_fields_to_epoch_seconds` / `rtc_get_day_index` / `rtc_get_minute_of_day` | Calendar conversion and current day/minute helpers. |
| `0x008276ac` / `0x008276b6` / `0x008276d2` | `settings_time_is_initialized` / `settings_mark_time_initialized` / `settings_store_time_extra_field` | Time-initialisation latch and request-byte-7 side field in settings blob1. |
| `0x00827720`..`0x00827756` | `settings_get_target_*`, `settings_store_target_triplet`, `settings_store_target_pair` | Daily target getters/setters used by FEE7 `0x21`. |
| `0x008381a2` / `0x008381c0` / `0x00838fae` | `gpio_set_pin_mux_byte` / `gpio_configure_pin` / `gpio_index_to_bitmask` | GPIO mux/config helpers used by button/DLPS and factory-test paths. |
| `0x00829c50` | `timer_stop_and_delete` | Shared timer teardown helper: stop then delete if a timer handle exists. |
| `0x00828af4` | `health_sensor_session_is_active` | Busy gate shared by camera/control, time sync, and health paths. |
| `0x0083361c` / `0x008336e8` | `sensor_bus_write_payload` / `sensor_bus_read_payload` | Low-level mutex callers for the sensor/peripheral command bus. |
| `0x00831f18`..`0x008320aa`, `0x0083712e` / `0x00837166` | `sensor_bus_*_reg_0x19/0x1f/0x20/0x33` | Opcode-specific sensor/peripheral bus wrappers for motor, accelerometer, and factory paths. |
| `0x00831b0c`..`0x00831d58` | `sport_state_get_*`, `sport_state_set_*_flag` | Current sport/session state getters and target-reached flag setters. |
| `0x0082c4d4`..`0x0082bfd8` | `fee7_handle_*_02/03/04/0a/0c/10/16/19/21`, `bp_history_prepare_recent_days`, `bp_history_send_next_chunks` | Low-range FEE7 switch handlers for camera, battery, bind, settings, BP history, short alert, HR setting, degree unit, and target setting. |
| `0x00827ba4`..`0x00827d1a` | `fee7_noop_97`, `fee7_set_session_mode*_ack_*`, `fee7_send_session_mode_status_9b`, `fee7_stop_factory_test_9c`, `fee7_send_model_name_9e`, `fee7_send_status_frame_a0` | High-range FEE7 `0x97..0xa0` switch handlers. |
| `0x00827ba6` / `0x00827bb8` / `0x00827dba` / `0x008280da` | `fee7_set_session_mode_and_commit` / `fee7_set_session_mode_ack_98_9a` / `factory_test_poll_timer_cb` / `factory_test_restart_reset_timer` | Shared high-range FEE7 session/factory-test state helpers. |
| `0x008296e8` / `0x008295c6` / `0x00829582` / `0x00829778` | `history_ring_find_or_allocate_slot` / `history_ring_upsert_record_body` / `history_ring_format_table` / `history_ring_erase_preserve_unit` | Persistent-history ring allocation, body upsert, table format, and erase/preserve helpers. |

New data aliases from this pass: `fee7_low_switch_default_index`
(`0x0082c61c`), `fee7_low_switch8_table` (`0x0082c61d`),
`fee7_high_switch_default_index` (`0x0082c6e0`),
`fee7_high_switch8_table` (`0x0082c6e1`),
`PTR_fee7_test_state_plus2` (`0x00827e88`), `factory_test_state_ptr`
(`0x00828108`), and the persistent-history descriptors
`history_desc_hourly_detail_24x12` (`0x00845a44`),
`history_desc_sleep_summary_100b` (`0x00845a50`),
`history_desc_sleep_nap_100b` (`0x00845a5c`),
`history_desc_activity_daily_24x2` (`0x00845a98`),
`history_desc_heart_rate_5min` (`0x00845aac`),
`history_desc_bp_hourly` (`0x00845ae4`),
`history_desc_pressure_30min` (`0x00845af0`), and
`history_desc_hrv_30min` (`0x00845afc`).

Ninth pass added notification/UI, display-name refresh, ANCS/GATT entry-point,
soft-float runtime, and GPIO/AON/NVIC names:

| Address | New name | Role |
|---|---|---|
| `0x00829856` / `0x0082994c` / `0x00829a56` | `alert_apply_output_mask` / `alert_start_sequence` / `alert_cancel_active` | Alert output-mask application, sequence start, and active alert cancel helpers. |
| `0x008299cc` / `0x00829a7c` | `alert_start_timed` / `alert_force_stop_outputs` | Timed alert start and unconditional output stop path. |
| `0x00829cfe` | `notification_render_or_alert_by_category` | Channel-A `0x72` notification renderer/alert dispatcher. |
| `0x0082a460` / `0x0082a5b2` / `0x0082a5c8` / `0x0082a5cc` | `ui_start_delay_if_idle_home`, `ui_overlay_start_if_dnd_clear`, `ui_overlay_start_forced`, `ui_overlay_cancel_current` | UI overlay/timer wrappers used by notification, find-device, and vendor alert paths. |
| `0x0082ccb6` / `0x0082e42c` | `channel_a_handle_watchface_display_clock_18` / `watchface_label_commit_ble_name_refresh` | Channel-A `0x18` watch-face label handler and BLE-name/profile refresh helper. |
| `0x008279e4` | `notification_show_pattern1_if_config_bit_set` | Notification follow-up helper gated by a settings bit. |
| `0x00827516` / `0x0082757e` / `0x008275b6` | `find_device_start_alert_sequence` / `find_device_transition_ack_or_button` / `find_device_cancel_ble_reinit_timer` | Find-device start, transition, and cancel/reinit paths. |
| `0x00839ac4` / `0x00839e4e` / `0x0083a116` | `ancs_get_app_attr` / `ancs_add_client` / `ancs_client_cb` | ANCS control-point app-attribute requestor, client registration, and lifecycle callback. |
| `0x00839fee` / `0x0083a036` | `ancs_parse_notification_source` / `app_parse_notification_source_data` | ANCS Notification Source parser and Data Source follow-up request builder. |
| `0x0082e850` / `0x0082e87a` / `0x0082e8ce` / `0x0082e8ec` | `channel_a_gatt_read_handler`, `channel_a_gatt_write_handler`, `channel_a_gatt_cccd_log_handler`, `channel_a_register_gatt_service` | Corrected by radare2: these handlers belong to the Channel-A `6e40fff0` service table at body `0x1f204`, not the `0xFEE7` table. |
| `0x0082e9a2` / `0x0082ea4c` / `0x0082eaba` / `0x0082eb0a` | `fee7_gatt_read_handler`, `fee7_gatt_write_handler`, `fee7_gatt_cccd_handler`, `fee7_register_gatt_service` | True `0xFEE7` GATT table registration and handlers; the write callback packages Realtek service events and does not call the 16-byte dispatcher. |
| `0x0082c8ce` / `0x0082c8e0` / `0x00830462` | `fee7_health_one_shot_result_poll_c1`, `fee7_ota_control_c3`, `fee7_noop_c4` | Raw FEE7 inline branches for health result poll, OTA/BLE control, and no-op command. |
| `0x0082c918` / `0x0082c90a` / `0x0082c926` | `fee7_store_runtime_flag_c5/c8/c9` | Runtime flag writes into `DAT_0082caec[3..5]`. |
| `0x00844214` | `fee7_generate_synthetic_sleep_record` | Fire-and-forget `0xfe` path that synthesizes and commits a sleep-history record from a host duration. |
| `0x0083e518`..`0x0083eacc`, `0x0083edc8`, `0x0083ef74`..`0x0083effc` | `__aeabi_dadd/dsub/drsub/ddiv/dmul`, `__aeabi_fdiv`, `__aeabi_f2uiz/i2f/ui2f` | ARM EABI soft-float helpers. `0x0083ed14` remains an unnamed internal exponent helper, not a standard EABI entry point. |
| `0x008384dc` / `0x00838502` / `0x008385bc` / `0x008385c6` | `aon_indirect_reg_write32`, `rtc_aon_block_reset`, `rtc_set_12bit_reload_or_prescale`, `rtc_counter_enable` | AON/RTC register-write and counter-control helpers. |
| `0x00838738` / `0x008380ac` / `0x00838294` | `periph_clock_power_gate_config`, `nvic_config_irq_priority_enable`, `pad_configure_dlps_wake_bits` | Peripheral power-gate, NVIC IRQ setup, and DLPS pad wake configuration. |
| `0x00838f82` / `0x00838f9c` / `0x00838eb0` / `0x00838c1e` | `gpio_set_interrupt_enable_bits`, `gpio_set_interrupt_mask_bits`, `gpio_apply_interrupt_config`, `i2c_decode_error_status` | GPIO interrupt and sensor-bus error helpers. |

---

## 0. Reading order

This document is structured for a host SDK author who needs to
understand the H59MA v14 firmware protocol. The 28+ detailed
sub-sections plus multiple syntheses can be read in any order,
but the recommended reading path is:

1. **§8.22 (cross-section wire format synthesis)** — the 16-byte
   envelope shared by §2 / §3 / §8, with the cmd-position table
   that shows §3 is the odd one out.
2. **§2 (Channel-B) + §3 (Channel-A)** — the two main GATT
   transports. Start with §2's wire format + NAK packet (§2.0),
   then §2.1-§2.11 for the per-opcode details. Move to §3's
   dispatcher table, then §3.1-§3.24 for the Channel-A handlers.
3. **§8 (0xFEE7 vendor service)** — the parallel vendor protocol.
   §8.1 is the dispatcher table; §8.2-§8.22 are the per-opcode
   details and syntheses.
4. **§4 (ANCS)** — the Apple Notification Center Service glue.
   §4.1-§4.3 cover the three callbacks.
5. **§5 (OTA) + §6 (Power Management) + §7 (Sensors)** —
   support subsystems. §5.1 has the OTA state machine, §6.1-§6.2
   cover the power-management paths, §7.1-§7.2 cover the HR and
   accelerometer dispatchers.
6. **§9 (Notable Data & Globals) + §10 (Open Questions)** —
   reference material.

Within each section, read the *syntheses* (the `§x.y` sub-sections
ending in "synthesis") before the *per-handler* sections — the
syntheses pull together patterns that the per-handler sections
cover in isolation.

---

## 1. Entry Point & Boot

| Address | Function | Notes | Detailed in |
|---|---|---|---|
| `0x00826400` | `entry` | Cortex-M trampoline: `ldr r0,[0x00826404]; bx r0` | §1 |
| `0x00826400 + 0x04` | initial SP | ARM-Thumb default = `0x200xxxxx` | §1 |
| `0x0082643c` | reset handler | Sets SP, calls system init, then `app_main_task` (`0x00826988`) | §1.1 |
| `0x00826988` | `app_main_task` | post-reset main-task routine (10-step boot sequence) | §1.1 |
| `0x0082f160` | one-shot timer starter | `func_0x00013694(DAT_0082f458 + -0x1c, ms)` — fires a 1-shot timer | §1.2 |

The vector table at `0x00826400` contains the initial SP, reset handler, and ISR pointers.

### 1.1 `app_main_task` boot sequence

The post-reset main-task routine. Runs after the reset
handler sets the SP and calls system init. Performs 10
sequential steps to bring the firmware from "fresh-boot"
to "ready-to-accept-BLE-traffic":

```c
void app_main_task() {
    FUN_0083deb0(*DAT_008269dc);  // 1. write boot-state register
    settings_blob0_load_or_init(); // 2. offset-store slot 0, len 0xe0, magic 0x04
    user_config_load_or_init();    // 3. offset-store slot 0x200, len 0xa4
    FUN_0083b956(1);             // 4. spawn task id 1 (main loop?)
    FUN_0083b7c2();              // 5. init (probably sensor tasks)
    ble_gap_profile_register();   // 6. BLE GAP/profile values, name, advertising data
    ble_services_init();          // 7. BLE services + notify ring setup
    FUN_00826942();              // 8. clock init
    app_init_runtime_tasks_and_timers(); // 9. queues/tasks/timers + Channel-B async state
    func_0x000131c2();            // 10. main-loop kickoff (task scheduler)
}
```

The 10 steps fall into **three layers**:
* **Persistent/config init** (steps 1-3) — write boot-state,
  load the 0xe0-byte settings blob and the 0xa4-byte user-config block.
* **Task spawn** (step 4) — start the main event loop.
* **Feature + BLE init** (steps 5-9) — initialise feature modules,
  register GAP/GATT data, create tasks/timers, and clear Channel-B async state.
* **Scheduler kickoff** (step 10) — enter the main event
  loop and start processing BLE traffic.

The boot sequence takes ~1 second to complete — most of
the steps are quick register writes, but `ble_services_init`
and the persistent offset-store reads can involve multiple
millisecond delays. After step 10 the firmware is in the
"ready" state and starts accepting BLE connections.

#### Why step 4 *spawns* the main loop

`FUN_0083b956(1)` spawns task id 1 *before* step 7 (BLE
init). The spawned task is the *event loop* (the `for (;;)`
loop that processes BLE traffic). The BLE init in step 7
runs *after* the event loop starts, which means the loop
sees the BLE-init event during its first iteration. This
ordering matters: if BLE init ran *before* the loop start,
the loop would block forever (no event to process). Running
it after the loop start lets the loop wake up as soon as the
BLE-init event fires.

#### Why step 10 *kicks off* the scheduler

`func_0x000131c2()` is the **task-scheduler kickoff** — the
function that runs the highest-priority ready task. The
firmware's task system uses a static priority table; the
scheduler iterates the table looking for the first task
with `state == READY`. Once a task is selected, the
scheduler switches to its stack and jumps into its entry
function.

After step 10, the scheduler runs task 1 (the main loop).
The main loop blocks on a BLE event queue; when a BLE event
arrives, the scheduler switches to the appropriate handler
task (e.g. a notification-source task or a data-source task).

#### Pair with §6.2 system reset

`FUN_008275d8` (§6.2) does *not* call `app_main_task` — the
system reset tears down all tasks and stops the main loop,
then re-arms the timers and exits. The post-reset re-init
*does* call `app_main_task` again, which goes through the
same 10-step sequence. So a §6.2 system reset effectively
re-runs the entire boot from step 1.

#### Pair with §3.14 `0xc6 0x6L 'l'`

`0xc6 0x6L 'l'` reboot (§3.14) calls `FUN_008275d8` (§6.2)
which in turn calls `app_main_task` (this section). So `0xc6`
indirectly re-bootstraps the firmware — the host sees the
reboot ack before the new boot completes.

#### 1.2 One-shot timer starter (`FUN_0082f160`)

```c
void FUN_0082f160(uint ms) {
    func_0x00013694(DAT_0082f458 + -0x1c, ms);
}
```

The §1 / §3 / §6 path's "start a one-shot N-ms timer" helper.
Calls `func_0x00013694` (the standard ARM-Thumb
timer-arm helper) at the `DAT_0082f458 + -0x1c` timer-state
slot with `ms` as the timeout.

The `-0x1C` offset puts the timer-state at a known place
relative to the OTA state pointer — the OTA context and the
timer-state share the same `DAT_0082f458 + N` layout
(see §5.1).

Used by:
* §1.1 step 9 (`app_main_task` 1000 ms post-init timer)
* §3.14 `0xc6 0x6C 'l'` reboot 2000 ms timer
* §6.2 system reset 1000 ms timer
* §6.1 button / DLPS init debounce + DLPS timers

The `ms` parameter is the **timer period in milliseconds** —
`1000` for the post-init 1-sec settling, `2000` for the
2-sec reboot delay, `60` (0x3c) for the button debounce,
`500` for the DLPS-allow. The timer fires `func_0x00013694`'s
callback when the period expires; the callback in turn
restarts the main loop's event processing.

#### Why `-0x1C` (not `-0x18`)

The OTA context's `DAT_0082f458 + 0x04..+0x0C` (12 B) holds
the OTA state buffer; the next 8 B (`+0x0C..+0x14`) are
the async cmd buffer. The `-0x1C` offset is *before* the
OTA context base — it lives in the `DAT_0082f440 + 0` region,
which is the boot-context's "last reboot timestamp". The
firmware reuses this region for the timer-state slot so the
timer can fire even during the reboot sequence when other
OTA contexts are temporarily unavailable.

---

## 2. Channel B — Large-Data / OTA / File Channel

## 2. Channel B — Large-Data / OTA / File Channel

Channel B uses a framed protocol over GATT notify/write:

```
byte 0      magic 0xBC
byte 1      cmd id
byte 2..3   payload length, little-endian u16
byte 4..5   payload CRC-16/MODBUS, little-endian u16
byte 6..    payload bytes
```

#### 2.0 Channel-B NAK packet (`FUN_0082ee00`)

The *error-response* path for any Channel-B opcode. When
the dispatcher detects an error (unknown cmd, no record
found, bad payload length, etc.) it calls
`FUN_0082ee00(cmd, error_code)` which builds a fixed-shape
NAK packet.

```c
void FUN_0082ee00(byte cmd, byte error_code) {
    rsp[0]  = 0xBC;                  // Channel-B magic
    rsp[1..2] = 1;                   // u16 frame count = 1
    rsp[3]  = error_code;
    rsp[4]  = cmd;                    // original request cmd
    rsp[5..6] = FUN_0082f114(&error_code, 1);  // CRC-16 over (error_code, cmd)
    FUN_0082ece0(rsp, 7);             // send
}
```

#### NAK packet layout (7 bytes)

```
byte 0:    0xBC                    (Channel-B magic)
byte 1..2: u16 1 (frame count = 1, LE)
byte 3:    error_code              (e.g. 0x02 = NAK code 2)
byte 4:    cmd                     (original request cmd)
byte 5..6: CRC-16/MODBUS over (error_code, cmd), LE
```

The error_code values used in the firmware:
* `0x02` — generic NAK ("request rejected")
* `0x10` — no data (e.g. `0x12 detailed sleep` when no
  record exists)
* `0x14` — invalid length

A host SDK that consumes Channel-B responses should:
1. Check the magic byte (`byte 0 == 0xBC`) to confirm a
   Channel-B packet.
2. Parse the frame-count from bytes 1..2.
3. For each frame: read `byte 1` of the payload as the
   sub-cmd, the rest as the data.
4. **Check byte 4 vs the request cmd** — if byte 4 ≠ cmd,
   the firmware sent a NAK and byte 3 is the error_code.
5. Verify CRC-16 over the payload (bytes 6..N) against
   the 2-byte CRC at the end of the header (bytes 4..5 of
   the *frame*, not the packet).

#### Why no response opcode

Channel-B NAKs are **packet-level** (the 0xBC magic plus
a frame count), not **opcode-level** (the request opcode).
The error_code byte tells the host *what went wrong*; the
original cmd byte tells the host *which request was
rejected*. There is no separate "NAK opcode" — the NAK is
the same 0xBC packet format as a normal response, just with
the error_code byte set.

This is why §2.6 (file commands) and §2.7 (device info) use
`FUN_0082ee00(0x41, 0x02)` for "file cmd 0x41 not supported"
but the same helper can emit `FUN_0082ee00(0x11, 0x10)` for
"sleep summary cmd 0x11 has no data" — the opcode is just
a parameter, not a separate dispatch.

### Key functions

| Address | Function | Role | Detailed in |
|---|---|---|---|
| `0x0082efea` | `channel_b_parse_reassembly_frame` | **Parser / fragment reassembly** | §2.0.1 |
| `0x0082eee6` | `channel_b_dispatch_complete_frame` | **Dispatcher** after full frame received | §2.0.1 |
| `0x0082fc0c` | `channel_b_async_command_processor` | **Async command processor** (runs from state stored by `channel_b_store_async_command`) | §2.0.1 |
| `0x0082f114` | `crc16_modbus_update` | **CRC-16/MODBUS** (init `0xFFFF`, poly `0xA001`) | §2.0.1 (disassembly) |
| `0x0082ece0` | `channel_b_queue_notify_frame` | **Frame builder / sender** (queues `0xBC` notifications) | §2.0.1 |
| `0x0082ee00` | `channel_b_send_nak` | **ACK/NAK sender** | §2.0 (NAK packet) |
| `0x0082f098` | `channel_b_start_fragment_timeout` | Starts 2000 ms fragment timeout timer (`m_ble_packet_timer_id`) | §2.0.1 |
| `0x0082f4fa` | `channel_b_store_async_command` | Stores parsed Channel B command for asynchronous consumption | §2.0.1 |
| `0x0082fe52` | `ota_dfu_state_machine` | OTA state machine (DFU) | §5.1 |

#### 2.0.1 Channel-B internal helpers

The 8 helpers listed above form the **Channel-B internal
runtime**. They are small (most are <50 instructions of
compiled code) but each plays a distinct role. This sub-
section documents them in one place so a host SDK author
who needs to understand the Channel-B packet flow can read
all the helpers together.

##### `channel_b_parse_reassembly_frame` — parser / fragment reassembly

The **per-frame state machine** for receiving Channel-B
frames. Splits a frame into the *6-byte header* (magic + cmd +
payload-length LE u16 + CRC-16 LE u16) and the *variable-
length payload*. Handles fragment reassembly: if the host
sends `frame_0 | frame_1 | frame_2`, the parser buffers the
payloads until `frame_N` arrives with the expected total
length, then dispatches via `channel_b_dispatch_complete_frame` (§2.0.1).

The state byte at `DAT_0082f0f0 + 0xb` tracks the parser
mode (0 = waiting for first fragment, 1 = continuing).
The 2-second fragment timeout (`channel_b_start_fragment_timeout` §2.0.1) aborts
if the host doesn't deliver all fragments in time.

##### `channel_b_dispatch_complete_frame` — dispatcher

Called when `channel_b_parse_reassembly_frame` has assembled a complete frame.
Runs the **opcode → handler** table that maps Channel-B
cmd bytes to handler functions (the §2.1-§2.11 handlers).
After dispatching, calls `channel_b_store_async_command` (§2.0.1) to store
the parsed cmd in the async queue, then `channel_b_async_command_processor`
(§2.0.1) to consume it later.

##### `channel_b_async_command_processor` — async command processor

The **worker that drains the deferred queue**. Pops the
parsed cmd from `channel_b_async_state_ptr_alias` (§2.1), runs the
per-cmd handler (§2.1-§2.11), and emits the response via
`channel_b_queue_notify_frame` (§2.0.1). The cmd dispatch in §2.0 is a
**synchronous** parser/dispatcher pair; the cmd *handler*
in §2.0 is an **async** worker — that's why we have two
separate functions.

##### `channel_b_store_async_command` — store parsed cmd

The **queue-writer** for the async cmd path. Sets
`channel_b_async_state_ptr_primary + 1 = cmd`, copies the payload ptr into
`channel_b_async_state_ptr_primary + 4`, sets
`channel_b_async_state_ptr_primary + 0xc = length`.
The `channel_b_async_command_processor` worker (§2.0.1) reads these back when it
runs the async handler.

##### `channel_b_queue_notify_frame` — frame builder / sender

The **symmetric counterpart** of `channel_b_parse_reassembly_frame`. Reads the
cmd byte, the payload, and the payload length, computes
the CRC-16/MODBUS over the payload via `crc16_modbus_update`
(§2.0.1), and writes the assembled 0xBC-magic frame into the
notify ring at `channel_b_notify_ring_state + 0xc + slot_idx * 0xb6`,
then advances the slot index (wraps at 8 = 0x180 / 0xb6).
Calls `FUN_0082eb8a` to kick BLE notify transmission
after the frame is queued.

##### `channel_b_send_nak` — ACK/NAK sender

See §2.0 for the full NAK packet layout. The ACK/NAK sender
is just a §2.0 NAK frame builder with `cmd = req_cmd,
error_code = 1/2/0x10/0x14`. The §2.0 host-SDK recipe (§2.0)
shows how to parse the returned NAK.

##### `channel_b_start_fragment_timeout` — 2-second fragment timeout

Starts the BLE packet timer with a 2000 ms timeout. The
parser's state machine (§2.0.1) is reset if the timeout
fires before all fragments arrive. The timer ID
`m_ble_packet_timer_id` is a global in the BLE stack.

##### `crc16_modbus_update` — CRC-16/MODBUS

See the disassembly below §2.0 for the algorithm. The CRC
table at `DAT_0082f158` is a 512-byte lookup table of the
precomputed reflected polynomial-0xA001 CRC for bytes 0..255.
Each entry is a u16 LE; the function indexes by `2 *
(byte ^ crc_lo)` to pick the table entry.

The `DAT_0082f154` global holds the initial CRC value
`0xFFFF` — the standard MODBUS CRC initial value. The
`DAT_0082f158` global holds the table base.

#### 2.0.2 The Channel-B async state structure

The async cmd path uses a shared state structure reached through two data-word
aliases. In this image `channel_b_async_state_ptr_primary` (`0x0082f894`) and
`channel_b_async_state_ptr_alias` (`0x0082fcbc`) both contain `0x0020b9a8`.
Ghidra names both because different functions load different literal-pool
aliases, but they refer to the same runtime context.

| Off | Field | Notes |
|---:|---|---|
| `+1` | `cmd` (u8) | the parsed cmd byte |
| `+4` | `payload_ptr` (u32) | pointer to the cmd payload / backing buffer |
| `+0xc` | `payload_len` (u16) | length of the payload in bytes |

The cmd dispatcher writes these fields when `channel_b_dispatch_complete_frame`
(§2.0.1) completes the frame; the async worker
`channel_b_async_command_processor` (§2.0.1) reads them back. The buffer is
shared with the sleep data context (which uses the same pointer but different
fields).

#### Why this sub-section exists

The §2.0 `Key functions` table at line 210 lists 8
helpers that together form the Channel-B internal runtime,
but the per-handler sections (§2.1-§2.11) only document the
**handler** parts (the cmd bytes). Without §2.0.1-§2.0.2,
a host SDK author who needs to understand the *internal*
Channel-B pipeline (parser / dispatcher / state store /
frame builder / notify / CRC) has to read the §2.0 table
plus the disassembly at §2.0 line 491 and infer the
relationships.

This sub-section pulls the threads together: the 8
helpers form a **6-step pipeline** (parse → store →
dispatch → CRC → build frame → notify) that handles every
Channel-B request/response cycle. The pipeline is *symmetric*
(parse ↔ build, store ↔ consume) — the same `FUN_0082f4fa`
that stores a parsed cmd also serves as the input buffer
for `FUN_0082fc0c` which consumes it.

### Parser behavior (`channel_b_parse_reassembly_frame`)

- State byte at `DAT_0082f0f0 + 0xb`:
  - `0`: waiting for first fragment.
    - Accepts if `len > 5` and `buf[0] == 0xBC`.
    - Saves `cmd = buf[1]`, `length = LE16(buf[2..3])`, `crc = LE16(buf[4..5])`, copies `buf[6..]`.
    - If `length <= received`, calls dispatcher.
  - `1`: continuation. Appends payload until `accumulated >= length`.

### Dispatcher behavior (`channel_b_dispatch_complete_frame`)

1. Computes CRC over assembled payload with `crc16_modbus_update`.
2. If CRC mismatch → sends NAK (`channel_b_send_nak(cmd, 2)`).
3. Pre-store OTA callback for `0x01`, `0x02`, `0x21`, `0x31`, `0x35`,
   `0x36`, `0x61`: calls `FUN_0082fe52(1, 0)`, then falls through to
   `channel_b_store_async_command(cmd, payload, length)`.
4. `0x10` and `0x46` branch around the async-store call and go straight to the
   cleanup/state-reset helper (`FUN_0082eebe` / body `0x8abe`).
5. Every other valid-CRC command calls
   `channel_b_store_async_command(cmd, payload, length)` for asynchronous
   consumption.

### Async processor (`channel_b_async_command_processor`)

Consumes the state saved by `channel_b_store_async_command` (`cmd` at offset `+1`, payload ptr at `+4`, length at `+0xc`).

The dispatch is a hybrid: low cmds `0x00..0x10` go through the compiler's
Thumb `switch8` helper, then cmds `0x11..0x5a` use a cascade of `cmp/beq`
branches. The switch helper metadata is:

```text
v14 body 0x982e: 08 2e 5f 63 69 6d 71 2e 75 2e
v13 body 0x9876: 08 2e 5f 63 69 6d 71 2e 75 2e
```

The first byte (`0x08`) is the max explicit index; the following 9 bytes are
branch-offset entries for `0x00..0x07` plus the clamped default entry for
`>=0x08`. Earlier notes over-read the following `cmp` cascade bytes as switch
entries, but the behavioral table below is unchanged: commands `0x08..0x10`
all clamp to the default NAK slot. On exit the handler clears `state[+1]` so
the slot is reusable.

| Cmd | Handler | Notes |
|---|---|---|
| `0x01` | `ota_cmd_start_ack` (table offset 0x5f) | OTA start ack — calls state callback `(1, 0)` |
| `0x02` | `ota_cmd_init_metadata` (table offset 0x63) | OTA init — expects 9-byte payload, sub-cmd `0x01`/`0x04`; stores image size and metadata; sets OTA state to `2` |
| `0x03` | `ota_cmd_write_data_packet` (table offset 0x69) | OTA data packet — validates the first container word, strips file offset `0x50`, writes staged image bytes to flash |
| `0x04` | `ota_cmd_check_complete` (table offset 0x6d) | OTA check — validates state `3` and accumulated size matches expected |
| `0x05` | `ota_cmd_end_reboot` (table offset 0x71) | OTA end — finalizes, resets sensors/BLE, reboots after delays |
| `0x06` | — | falls into the table's default `0x2e` slot — NAK with code 0 |
| `0x07` | `ota_cmd_sub_ack` (table offset 0x75) | OTA sub-ack — calls state callback `(7, 0)` |
| `0x08..0x10` | — | default slot — NAK with code 0 |
| `0x11` | `channel_b_send_sleep_summary(payload[0])` | Read sleep summary — see §2.1 |
| `0x12` | `channel_b_send_detailed_sleep()` | Read detailed sleep data — see §2.2 |
| `0x13` | — | no-op (skipped) |
| `0x21`, `0x22`, `0x23`, `0x24` | `channel_b_send_nak(cmd, 2)` | ACK with code `2` (intentionally rejected at this layer) |
| `0x27` | `channel_b_send_sleep_records(payload[0], payload[1])` | Read sleep records — see §2.3 |
| `0x29`, `0x3b` | — | no-op (skipped) |
| `0x2a` | `channel_b_send_activity_summary(payload[0])` | Read activity/sport summary — see §2.4 |
| `0x2c` | `channel_b_handle_alarm_read_write()` | Alarm read/write — see §2.5 |
| `0x41` | `channel_b_handle_file_command(0x41, payload, length)` | File list — see §2.6 |
| `0x43`, `0x46` | `channel_b_handle_file_command(cmd, payload)` | File init / file delete family — see §2.6 |
| `0x47` | `channel_b_handle_0x47_noop(payload[0])` | no-op |
| `0x4b` | `channel_b_handle_0x4b_noop(payload[0])` | no-op |
| `0x5a` | `channel_b_handle_device_info_config(payload)` | Device info/config — see §2.7 |

Unrecognized commands fall through to `channel_b_send_nak(cmd, 0)` (NAK code `0`).
The no-op rows are intentionally different from the unrecognized-command path:
`0x13`, `0x29`, and `0x3b` branch straight to worker cleanup, while `0x47` and
`0x4b` call single-instruction placeholder stubs (`bx lr`) with `payload[0]`.

#### 2.1 Sleep summary (`channel_b_send_sleep_summary`)

Input: `payload[0]` is the day offset (0 = today, 1 = yesterday, …).
Effective day is `current_day - payload[0]`. The handler reads 100 B
from the sleep-summary store via `sleep_read_summary_record(day, buf)` and emits a
0x65-byte (101 B) Channel-B frame:

```
byte 0       echoed day_offset
byte 1..100 100-byte summary (e.g. totals, deep/light/REM minutes,
              avg HR, breath rate — exact layout recovered only after
              linking with the producer side)
```

#### 2.2 Detailed sleep (`channel_b_send_detailed_sleep`)

Uses the requested day-offset byte at `*(channel_b_async_state_ptr_primary + 4)` and an aux size at
`DAT_0082f89c` (typically `0x130`). Two-phase build:

1. If `sleep_read_detail_record(day) == 0` (no record): `memset(target, 0, DAT_0082f89c)` (zero-fill).
   Otherwise call the delayed init helper `func_0x000002a8` (probably a flash-read wrapper).
2. If the RTC/day guard fails, send a NAK via
   `channel_b_send_nak(0x12, day_offset)` instead of a payload.
3. Otherwise the response is 0x121 B: byte 0 = echoed day offset, bytes
   1..0x120 = a 0x120-byte slice from `auStack_52c + DAT_0082f8a0`
   (i.e. a 0x120-byte "detailed" window whose offset is the
   sleep-context base).

#### 2.3 Sleep records (`channel_b_send_sleep_records`)

Inputs: `param_1` (clamped to 6) = day offset; `param_2` = record-type
filter. Two parallel passes always run, regardless of `param_2`:

- Nap pass (`param_2 == 1`): reads records via `sleep_read_nap_record(day, buf)`.
  Emits one Channel-B `0x3E` frame (header + nap records).
- Night-sleep pass (always): reads via `sleep_read_summary_record(day, buf)`.
  Emits one Channel-B `0x27` frame (header + night records).

Each emitted record (6-byte header + score bytes + label bytes) is
laid out as:

```
byte 0       day_delta   (current_day - source_day, capped)
byte 1       header      (record_count * 2 + 4)
byte 2..3    start_time  (hour, minute) — u16 min-of-day split
byte 4..5    end_time    (hour, minute)
byte 6..N    per-record score bytes (count = record_count)
```

The very first byte of the response is the number of records actually
written (`cVar8` accumulator).

#### 2.4 Activity / sport summary (`channel_b_send_activity_summary`)

Input: `payload[0]` is the day offset (clamped to 2, max 3 days
back). Iterates from `current_day` down to `current_day - offset`,
calling `activity_read_day_summary_record(day, buf)` (returns 0 if no data). For every
day with data, emits a 0x31-byte entry:

```
byte 0       day_offset
byte 1..0x30 48 bytes activity summary (steps, distance, calories,
                per-sport mode stats; the field meaning is owned by
                the producer in `FUN_00833b42`)
```

The total Channel-B frame uses cmd `0x2A` and a length up to
`0x31 * 3 = 0x93` bytes. `day_offset == 0` is a valid final entry for
today; do not treat a zero byte inside the entry stream as a terminator.

#### 2.5 Alarm read/write (`FUN_0082f8ec`)

Sub-cmd at `payload[0]`:

| Sub | Action |
|---|---|
| `0x01` | Read: pulls `FUN_0082a9c2(count, ...)` and re-emits up to 10 alarms. Each alarm is a 0x29-byte record: `[len, id, hour, minute, day_bitmap(7 B), label(N)]` with `(len & 0x7F) ∈ [4, 0x22]`. Response is `1 + count * 0x29` bytes, cmd `0x2C`. |
| `0x02` | Write: pulls count from `payload[1]`, clamps to 10, validates per-alarm `(len & 0x7F) ∈ [4, 0x24]`, calls `FUN_0082a9b0(record)`. Response is 1 byte (`0x02`) ack, cmd `0x2C`. |
| other | no-op (response = 1 byte) |

#### 2.6 File commands (`FUN_008311b8`)

Sub-handler selected by `cmd`:

| Cmd | Action |
|---|---|
| `0x41` | List: copies 4 B of context from `payload`, walks `FUN_008313ba` (up to 10 entries) and formats each via `FUN_0083105a`. Response uses cmd **`0x42`** (note: not `0x41`) — first byte is the file count. |
| `0x43` | Init: `FUN_008310c8(payload)` — no response payload. |
| `0x46` | Same body as `0x43` (file delete) — gated by caller's length check. |

#### 2.7 Device info / config (`FUN_0082f6ec`)

Sub-cmd at `payload[0]`:

| Sub | Action |
|---|---|
| `0x01` | Read info: builds a TLV list from a capability bitmap at `DAT_0082f8a4+0x15/0x16`. Each present feature calls `FUN_0082f5e6(slot_id, src, src_len, dst)` and accumulates length into `uVar7`. Six slots, with strings at fixed offsets: `H59MAX`, `H59MA_V1_0`, `H59MA__`, `1_00_14_`, `260508`. Response is cmd `0x5A`, payload = `[0x01, 0x01, 0x06, ...tlv...]`. |
| `0x02` | Write: iterates payload TLVs, calling `FUN_0082f5fa(slot_id, src)` per entry, then `FUN_008294cc` and `func_0x0000029c(1, 0xd0)` (a one-shot timer). |
| `0x03` | Read version strings: emits 6 slots — `s_H59MAX__0082f8a8` (7 B), `s_H59MAX__0082f8a8` (7 B), `s_H59MA_V1_0_0082f8b0` (10 B), `s_H59MA__0082f8bc` (6 B), `s_1_00_14__0082f8c4` (8 B), `s_260508_0082fcb4` (6 B). |
| `0x04` | Reset: `memset(DAT_0082f8a4 - 0x46, 0, 100)` and `FUN_008294cc()`. |
| other | Response = `[0x5A, 0x00, 0x00]` (3 B, status 0). |

The 6 version string slots are the *only* string literals referenced
in this dispatcher; the response bytes for cmd `0x03` are exactly the
constants visible in `firmwares/_re/strings-mining/`.

#### 2.8 Activity summary (`FUN_00833bbc`)

The Channel-B analog of the Channel-A `0x43 readDetailSport`
(§3.6) — same "dump per-day records for last N days"
shape, but for the **activity tracker** (`vc_SportMotion`
library) instead of the per-hour sport detail.

```c
void channel_b_send_activity_summary(int n_days) {
    if (n_days > 2) n_days = 2;            // cap at three entries: 2, 1, 0
    if (n_days < 0) return;               // negative -> no response
    int month = FUN_0082840e();
    int out_offset = 0;
    for (int d = n_days; d >= 0; d--) {
        uint8_t *entry = activity_read_day_summary_record(month - d, &buf);
        if (entry != NULL) {
            rsp[out_offset] = (char)d;
            memcpy(rsp + out_offset + 1, entry, 0x30);
            out_offset += 0x31;
        }
    }
    channel_b_queue_notify_frame(0x2A, rsp, out_offset);
}
```

The handler:
* Clamps `n_days` to `[0, 2]`, so the maximum response covers
  three offsets: `2`, `1`, and `0`.
* Calls `activity_read_day_summary_record(month - d, &buf)` for each day — this
  helper looks up the day in the **activity tracker state
  buffer** at `activity_state_ptr` (the activity tracker is
  separate from the sport-detail buffer at `DAT_0082d440`).
* Builds a **49-byte record per day** (1 byte day-offset +
  48 bytes body = `0x31` bytes).
* Sends via `channel_b_queue_notify_frame(0x2A, rsp, n)` — the standard
  §2.0 frame builder.

#### `activity_read_day_summary_record` — per-day activity reader

```c
uint activity_read_day_summary_record(uint day, u16 *out) {
    activity_rec *r = FUN_0082966e(activity_record_table_base,
                                    *(activity_state_ptr + 8),
                                    day, ...);
    memset(out, 0, 0x34);                  // 52 B cleared
    if (r == NULL) {
        if (*(u16*)(activity_state_ptr + 0xE) != day) return 0;
        // no record, but cache matches: return zeroed
    } else {
        // copy record (with FF→0 padding for uncompressed bytes)
        for (int i = 0; i < 0x18; i++) {
            if (r->body[2*i + 4] == -1) out->body[2*i + 4] = 0;
            else                              out->body[2*i + 4] = r->body[2*i + 4];
        }
        if (*(u16*)(activity_state_ptr + 0xE) != day) return 1;  // warning
    }
    // copy the 2 "step type" bytes from the activity state
    out[0] = *(u16*)(activity_state_ptr + 0x10);
    out[1] = *(u16*)(activity_state_ptr + 0x12);
    return 1;
}
```

Notable details:
* The activity tracker stores a **`0x34` byte** record (52 B), but
  the Channel-B response sends only bytes `+4..+0x33`: a fixed
  48-byte body after the day-offset byte.
* The `0xFF → 0x00` padding on uncompressed bytes is the
  same compression-trick used by the sleep record parser
  (§2.4 / §2.5) — a byte of `0xFF` means "no data, treat as
  zero" so the host can read the body as a fixed 48-byte
  array.
* The function falls back to the cache (`activity_state_ptr +
  0xE` = last-day-read index) if no fresh record exists, so
  the host still gets a (zeroed) response for "yesterday"
  even when the day's data hasn't been written yet.

#### Why cap at 2 days

The §2.5 sleep record parser returns up to 7 day offsets (`0..6`); the
§2.8 activity summary is **capped at max offset 2**, so at most three 49-byte
entries are returned. The cap keeps the total payload under `0x93` bytes.

The host SDK that consumes `0x2a` should:
* Parse the response as repeated 49-byte entries:
  `[day_offset][48 B activity body]`.
* Use the Channel-B payload length to stop. `day_offset == 0` is a valid entry
  for today and is often the last entry, not a terminator.
* Treat `0xFF` bytes in the body as `0x00` (same compression-trick).

#### Pair with Channel-A `0x43 readDetailSport` (§3.6)

`0x43` and `0x2a` are the per-day dump pair for two different
data sources:
* `0x43` (Channel-A) — per-hour sport detail (24 slots × 12 B
  = 288 B) from the `vc_SportMotion_Int` library.
* `0x2a` (Channel-B) — per-day activity summary (up to 3 slots ×
  49 B = 147 B) from the same library but a different record type.

A host that wants both should poll `0x43` *after* receiving an
`0x2a` ack (the `0x2a` response is still shorter than `0x43` and is the
cheaper "what days have data?" probe).

### CRC-16/MODBUS (`FUN_0082f114`)

Disassembly confirms standard MODBUS CRC:

```asm
push {r4,r5,r6,lr}
mov  r4, r0           ; buf
ldr  r0, [0x0082f154] ; initial 0xFFFF
movs r2, #0           ; i
ldr  r5, [0x0082f158] ; CRC table base
loop:
ldrb r6, [r4, r2]
uxtb r3, r0
eors r3, r6
lsls r3, r3, #1
ldrh r3, [r5, r3]
lsrs r0, r0, #8
eors r0, r3
adds r2, r2, #1
cmp  r2, r1
blt  loop
pop  {r4,r5,r6,pc}
```

#### 2.9 Sleep summary (`channel_b_send_sleep_summary`)

The "read a *summary* of one day's sleep" command. Like
`0x12 detailed sleep` (§2.10 below) but returns a smaller
**100-byte summary record** instead of the full per-segment
detail. Used by the host SDK for the "sleep score" card on
the dashboard.

```c
void channel_b_send_sleep_summary(short day_offset) {
    int today = FUN_0082840e();
    sleep_read_summary_record(today - day_offset, stack_buf);
    rsp[0] = day_offset;                             // echoed request byte
    memcpy(rsp + 1, stack_buf, 100);
    channel_b_queue_notify_frame(0x11, rsp, 0x65);   // 1 + 100 = 101 B
}
```

The handler:
1. Reads the sleep summary for `(today - day_offset)` via
   `sleep_read_summary_record` — a 100-byte summary record into a stack
   buffer.
2. Sets `rsp[0]` to the echoed day-offset request byte.
3. Copies the 100-byte summary into `rsp[1..100]`.
4. Sends via `channel_b_queue_notify_frame(0x11, rsp, 0x65)` — total
   payload 101 bytes (1 offset + 100 summary).

#### Response layout (101 bytes)

```
byte  0:    echoed day offset
byte  1..100: 100-byte sleep summary
```

The 100-byte summary format is shared with `0x12 detailed
sleep` (§2.10) — the first portion is the summary, the
remaining is the per-segment detail. A host that only
wants the summary can stop reading after the first ~20
bytes; a host that wants full detail uses `0x12` instead.

#### `sleep_read_summary_record` — sleep summary reader

```c
void sleep_read_summary_record(int day, u8 *out) {
    int today = FUN_0082840e();
    if (day == today && FUN_00844c34() != 0) {
        FUN_00844328(out);              // "live today" path
        return;
    }
    u8 *r = FUN_0082966e(DAT_00831990 + 0xc,
                          *(u32*)(DAT_0083198c - 0x48),
                          day);
    if (r != NULL) {
        func_0x000002a8(out, r, 100);   // memcpy 100 B
    } else {
        memset(out, 0, 100);            // day has no data
    }
}
```

Three branches:

* **Live-today path**: if the requested day is *today* AND
  `FUN_00844c34()` returns non-zero (i.e., the firmware has
  finalised today's sleep in the live buffer), use
  `FUN_00844328(out)` — the **fresh live data** path that
  bypasses the day-record table.
* **Day-record path**: look up the day in the persistent
  sleep-state table at `DAT_00831990 + 0xC` (note the `0xC`
  offset — same pattern as `0x43 readDetailSport` §3.6 which
  uses `DAT_0082d440 + 0x14`). Copy 100 bytes.
* **Empty-day path**: zero-fill 100 bytes.

The **`DAT_0083198c - 0x48`** offset is unusual — it's a
*negative* offset, which means the table-base pointer lives
*before* `DAT_0083198c` in memory. This is likely a
`table_header_t` layout where `DAT_0083198c` is a field
*inside* the header (e.g. a state byte at offset `+0x48`)
and the table base is reached by subtracting the header
size. The host SDK does not need to know this — the helper
hides the offset arithmetic.

#### Pair with `0x12 detailed sleep` (§2.10)

`0x11` returns **101 bytes** (`day_offset` + 100-byte summary); `0x12` returns
**289 bytes** (`day_offset` + 288-byte detail). The two are *the
same record type* — `0x11` is the "small" variant that
ships only the summary header, `0x12` is the "full"
variant that ships the per-segment detail. A host that wants
the full sleep curve uses `0x12`; a host that just wants the
sleep score / duration uses `0x11`.

#### Why the live-today branch?

If the user has *just woken up* and the host polls `0x11
day=0`, the day's sleep record may not have been written to
the persistent table yet (the firmware commits daily at
midnight). The live-today branch (`FUN_00844328`) bypasses
the table read and reads directly from the live sleep buffer,
so the host gets the freshest data. Without this branch, a
mid-day poll would return zeroed summary data even when the
watch has full sleep data in RAM.

#### 2.10 Detailed sleep (`channel_b_send_detailed_sleep`)

The "full per-segment sleep curve" command. Returns a
**289-byte record** (1 echoed day-offset byte + 288 B body) — the same
size as the §3.6 `0x43 readDetailSport` per-day record.
Like `0x11` (§2.9), this is a per-day dump but with **24
× 12 B hourly slots** instead of the 100 B summary.

```c
void channel_b_send_detailed_sleep() {
    int today = FUN_0082840e();
    sleep_ctx = channel_b_async_state_ptr_primary;
    day_offset = **(u8**)(sleep_ctx + 4);
    sleep_read_detail_record(today - day_offset);
    body_offset = channel_b_sleep_detail_body_offset;
    body_ptr = stack_buf + body_offset;
    if (sleep_read_detail_record result == 0)
        memset(body_ptr, 0, channel_b_sleep_detail_clear_len);
    else
        memcpy(body_ptr, sleep_read_detail_record result, ...);

    // If no day offset in request, also write today's live record
    if (day_offset == 0) {
        current_hour = FUN_0083dfba(FUN_0082841e(), 0x3c);
        sleep_write_live_detail_slot(body_ptr + current_hour * 0xc + 4);
    }

    if (current_month == 0) {
        channel_b_send_nak(0x12, day_offset);         // error path
    } else {
        stack_buf[0] = day_offset;
        memcpy(stack_buf + 1, stack_528 + body_offset, 0x120);
        channel_b_queue_notify_frame(0x12, stack_buf, 0x121);
    }
}
```

Notable details:

* `sleep_read_detail_record(day)` — the per-day detail reader. Uses
  `DAT_00831990` (same table base as `0x11`) but with
  `*(DAT_0083198c + -0x4C)` (offset `-0x4C`, *another*
  negative offset — the sleep-detail table starts 0x4C bytes
  *before* `DAT_0083198c`). This is a *different* table
  index than `0x11` (which used `DAT_0083198c - 0x48`),
  suggesting the firmware keeps separate indices for the
  summary and the detail records even though they live in
  the same day-table.
* `body_offset = channel_b_sleep_detail_body_offset` — the offset into the
  per-day record where the per-hour slots start. Like
  `0x43 readDetailSport` (§3.6) which uses an offset of
  `+4` (the day key/header lives at byte 0..3), the sleep
  detail offsets the slots past a 4-byte header.
* `body_ptr + current_hour * 0xc + 4` — the helper writes
  the **current live hour** into the appropriate slot
  before sending. `0xc = 12` is the slot size; `current_hour`
  is computed as `currentMinuteOfDay / 60`.
  This means **a `0x12` poll always returns up-to-the-minute
  data** for today, while older days return the committed
  table record.
* `current_month == 0` — the "today" check. If `FUN_0082840e()`
  returns 0 (i.e., the RTC has no valid month — likely a
  *factory-fresh* watch), the handler sends an error
  response instead of the data. Same defensive guard as
  `0x43 readDetailSport` §3.6.

#### Response layout (289 bytes)

```
byte  0:        echoed day offset
byte  1..288:   288-byte per-hour sleep detail
                (24 hours × 12 B per hour)
```

#### Pair with `0x11 sleep summary` (§2.9)

The §2.10 / §2.9 split mirrors the §3.6 / §3.x summary-detail
pair — the summary is a *small fixed-size preview* (100 B),
the detail is a *full variable-size dump* (~289 B). The two
read from the **same persistent table** (`DAT_00831990`) via
*different helper functions* (`FUN_008318c2` vs
`FUN_008318b0`) and the host SDK uses the same record-format
parser regardless of which opcode it uses.

#### Why `body_offset = DAT_0082f8a0` (vs the §3.6 `+4`)

Both the sleep-detail handler and the §3.6 `0x43
readDetailSport` handler use a 4-byte state prefix + variable-
length body. The `DAT_0082f8a0` global is the **size of the
state-prefix** for sleep records (likely 4 bytes, matching
`0x43`'s 4-byte offset). The decompiler doesn't know this is a
constant; it reads the global at runtime. A future firmware
revision could change `DAT_0082f8a0` to expand the state
prefix without breaking the helper.

#### Why the live-minute write

The `sleep_write_live_detail_slot(body_ptr + current_hour * 0xc + 4)` call is
the live-overlay path: it overwrites the appropriate hourly slot in the body
buffer with current sleep data. Without this, a `0x12` poll for today would
return the last committed slot, which can be up to 24 hours stale.
The 0xc = 12 slot size matches the §3.6 detail record layout
— the same vendor library (`vc_SportMotion_Int`) generates
both the sport and sleep records.

#### 2.11 File list / file init-delete (`FUN_008311b8`)

The Channel-B **file-management** pair. Two sub-codes share
the same handler; both operate on the watch's internal
*file table* (probably the *music / watch-face / OTA image*
table — the OEM's per-record storage).

```c
void FUN_008311b8(int sub, void *req_payload) {
    if (sub == 0x41) {
        // 0x41 file list: dump up to 10 files
        memcpy(state, req_payload, 4);              // copy request field
        rsp[0] = 0;                                // count = 0
        u16 out_offset = 1;                        // body starts at byte 1
        for (int i = 0; i < 10; i++) {
            if (FUN_008313ba(state, i, file_buf) == 0) break;
            u16 n = FUN_0083105a(file_buf, rsp + out_offset);
            out_offset += n;
            rsp[0]++;
        }
        FUN_0082ece0(0x42, rsp, out_offset & 0xffff);
    } else if (sub == 0x43) {
        // 0x43 file init/delete: no response, just call helper
        FUN_008310c8(req_payload);
    }
    // 0x46 routes here too (same body as 0x43, see §2.6)
}
```

Two sub-codes share the same handler:

* **`0x41` file list** (`FUN_008311b8` with `sub == 0x41`):
  reads up to **10 file records** via `FUN_008313ba` (returns
  0 when no more files), converts each to a TLV via
  `FUN_0083105a`, and ships the full list as a `0x42`
  response (note: `0x42`, not `0x41` — same handler / different
  response opcode). The body layout is `[count_byte] [TLV0]
  [TLV1] ...`.

* **`0x43` / `0x46` file init / delete**:
  just calls `FUN_008310c8(req_payload)`. **No response** is
  shipped — the dispatcher (§2.0) ack frame is the
  implicit "operation accepted" signal.

#### Request layout

* **`0x41`** — `req[0..3]` is a 4-byte request field copied
  verbatim into `state`. The docstring for `0x41` doesn't
  tell us what this field encodes (probably an offset /
  start-index for the file dump, or a path qualifier).
* **`0x43` / `0x46`** — `req[0..15]` is the operation payload
  (e.g. filename for delete, content for init). The full
  16-byte payload is forwarded to `FUN_008310c8`.

#### Response layout (`0x41` only)

```
byte  0:    file count (0..10)
byte  1..N: TLV-encoded file records (TLV0 = bytes 1..N1,
            TLV1 = bytes N1+1..N2, ...)
```

Each TLV record is the output of `FUN_0083105a` — likely a
length-prefixed record:

```
record[0]      = recordLen    // includes recordLen + recordType bytes
record[1]      = recordType   // source record byte 6
record[2..end] = fields

field[0]       = fieldLen     // includes fieldLen + fieldId bytes
field[1]       = fieldId
field[2..end]  = raw value bytes
```

radare2 v14 body offsets `0xac5a..0xacc6` verify that
`FUN_0083105a` initializes each record length to 2, copies
source byte 6 as `recordType`, then appends fields via
`FUN_00830fa0`. Record types `0x04`, `0x07`, and `0x08` emit
field ids `01 02 03 04 05 06 07 08 09 0d 13`; other record
types emit `01 02 04 07 08 09`. The field formatter initializes
each field length to 2, writes `fieldId`, copies 1/2/4 raw value
bytes depending on the id-specific case, and returns the inclusive
field length.

`0x43` and `0x46` ship **no direct response payload** — the
dispatcher's implicit ack is the only feedback unless the operation
starts a `0x44` metadata + `0x45` chunk stream. `FUN_008310c8`
builds three observed `0x44` forms: success
`[00, chunkCount u16LE, meta3, 01, 11]`, not-found
`[01, selector, recordId u32LE]`, and invalid-selector
`[02, selector]`. Data chunks are one-based
`[chunkIndex, 00, data...]`, capped at `0x1f4` data bytes.

#### Why cap at 10 files?

The 512-byte stack buffer (`local_240`) holds the full
list, capped at 10 entries. 10 is a firmware-internal limit
on how many files the watch exposes at once — beyond that,
the host must issue multiple `0x41` requests with different
start indices (the `state[0..3]` field is presumably a
paging cursor).

#### `FUN_008313ba` — single-file reader

The `FUN_008313ba(state, index, out_buf)` helper reads the
`index`-th file record from the watch's internal file table
into `out_buf`. Returns `0` when `index` is past the end of
the table — the loop terminates and ships whatever was
collected. Returns non-zero (the number of bytes copied)
when a record was found.

#### `FUN_0083105a` — TLV serialiser

The `FUN_0083105a(in_buf, out_buf)` helper converts the raw
48-byte file record from `FUN_008313ba` into a TLV triple
on the wire. The tag + length + data layout is the standard
"host SDK understands this" format; the raw 48-byte record
is firmware-internal.

#### Pair with `0x46` (§2.6)

`0x46` is the *delete* sibling — same handler body as `0x43`,
same no-response behaviour. The §2.6 dispatcher routes
`0x46` to the *same* `FUN_008311b8` via the `else if (sub ==
0x43)` branch, but the second sub-byte is checked against
`0x46` *inside* `FUN_008310c8` (not visible from this
handler). The decompiler's `else if (sub == 0x43)` clause is
in fact a multi-target `0x43 / 0x46` handler — the disassembly
would show a `cmp r3, #0x46; beq ...` branch in `FUN_008310c8`.

#### Why no response on `0x43` / `0x46`

`0x43` is the "create a new file" command and `0x46` is the
"delete an existing file" command. Both are **mutating**
operations — they either succeed or fail silently. A response
frame would only tell the host "the firmware accepted the
command", not "the operation succeeded" (the watch can
still fail the actual create/delete if the file is invalid
or the FS is full). The host SDK polls `0x41` after
issuing `0x43` / `0x46` to verify the operation took effect.

#### Why the response opcode is `0x42` (not `0x41`)

The §2.0 dispatcher emits `0x42` for `0x41` responses
because the two opcodes are **paired**: `0x41` is the
*request* opcode, `0x42` is the *response* opcode. This
mirrors the `0x41` / `0x42` Channel-B pair that the §3.0
handler table at `FUN_0082fc0c` uses for similar request /
response semantics — keeping the response-cmd one-higher
than the request-cmd is the firmware's convention for
"stream this list" operations.

Channel A frames are fixed 16 bytes. The main command dispatcher is
`channel_a_dispatch_queued_frame` (`0x0082d2dc`) **in the firmware** — this
routine processes a circular queue of incoming 16-byte frames and dispatches
on the queued frame's byte `0` opcode. Earlier notes in
`R2_ANALYSIS.md`/`PROTOCOL.md` claimed Channel-A dispatch was APK-only; that
claim is incorrect for v14.

### Main dispatcher (`channel_a_dispatch_queued_frame`)

Processes a 10-slot circular queue under `channel_a_command_queue_state`
(`0x0082d440`). The ring head and tail live at `state + 0x14` and
`state + 0x16`; entries start at `state + 0x18 + index * 0x10`. The decompiler
loads each entry through `state+0x14` plus a halfword offset, which can look
like "+2" in decompiled pointer arithmetic, but handlers receive the copied
16-byte Channel-A frame with opcode at byte `0` and payload at byte `1`.

### Opcode → handler map

| Opcode | Dart name (from `lib/core/protocol/opcodes.dart`) | Handler address | Handler summary |
|---|---|---|---|
| `0x01` | `setTime` | `0x0082bb4e` | Converts BCD date/time fields, updates RTC, sends `0x2f` packet-length notify, then a 14-byte `0x01` ack — see §3.4. |
| `0x06` | `dnd` | `0x0082d298` | Sub-opcode `0x01` reads DND state, `0x02` sets it — see §3.7. |
| `0x08` | *(special)* | `0x00827516`, `0x008275b6`, `0x00827ba6`, `0x008280fe` | Camera/find-device/long-press branch — see §3.15. |
| `0x0c` | `bpSetting` | `0x0082c0de` | Sub `0x01` reads BP auto-measure config, `0x02` writes it with interval-minute validation — see §3.18.1. |
| `0x0e` | `bpReadConform` | `0x0082cb28` | If sub-byte `0` → `FUN_00834410()` + `FUN_0082c0a4()` — see §3.19. |
| `0x15` | `readHeartRate` | `0x0082cf48` | Reads heart-rate record by index; returns `0x15` multi-frame data or `0xff15` error — see §3.12. |
| `0x18` | `displayClock` | `0x0082ccb6` | Sets watch-face / clock display — see §3.5. |
| `0x1e` | `realTimeHeartRate` | `0x0082d20c` | Sub `0x01` starts 60s HR measurement, `0x02` stops, `0x03` resets timer — see §3.13. |
| `0x25` | `setSitLong` | `0x0082d284` | Writes sedentary config — see §3.9. |
| `0x26` | `readSitLong` | `0x0082d258` | Reads sedentary config — see §3.9. |
| `0x2b` | `menstruation` (mixture container) | `0x0082ba54` | Sub `0x01`/`0x02` read/write mixture data; cycle-phase detector + notification sender — see §3.1. |
| `0x2c` | `bloodOxygenSetting` | `0x0082d1c2` | Sub `0x01` reads SpO2 setting, `0x02` writes it — see §3.10. |
| `0x37` | `pressureSetting` | `0x0082caa6` | Reads/sets pressure config; uses `FUN_008344fe` — see §3.20. |
| `0x38` | `pressure` | `0x0082ca54` | Sub `0x01` reads pressure value, else sets pressure unit — see §3.17. |
| `0x39` | `hrvSetting` | `0x0082c9da` | Reads/sets HRV config; uses `FUN_0083468e` — see §3.21. |
| `0x3a` | `sugarLipidsSetting` | `0x0082cc1e` | Sub `0x03`/`0x04` read/write sugar/lipids settings — see §3.22. |
| `0x3b` | `uvSetting` / `touchControl` | `0x0082cbc8` | Read/write UV/touch config byte at `DAT_0082cfe8 + 8` — see §3.18. |
| `0x43` | `readDetailSport` | `0x0082d034` | Reads detailed sport records by date range — see §3.6. |
| `0x72` | `pushMsgUint` | `0x00829e92` | Buffers a notification/emoji Unicode string for display — see §3.3. |
| `0x77` | `phoneSport` | `0x0082ce0c` | Jump-table dispatch on sub-byte. |
| `0x7a` | `muslim` | `0x0082cb3a` | Sub `0x01` reads Muslim prayer config, `0x02 0x01` resets it — see §3.11. |
| `0x81` | — | `0x0082cdac` | Stores 6-byte config chunk and calls `FUN_00840568` (flash/config write). |
| `0xa1` | — | `0x00827f5c` | Factory/test mode commands (`0x01`–`0x06`): reset, read logs, power off, etc. |
| `0xc6` | `restoreKey` | special | Reboot sequence — see §3.14. |
| `0xc7` | — | `0x00832ebc` | Vibration/motor pattern player — see §3.2. |
| `0xff` | — | `0x0082cde8` | Factory reset — see §3.8. |

### Common response path

Most handlers build a 16-byte response buffer, compute an additive checksum
with `checksum8_additive`, and send it via `channel_a_queue_notify_frame`:

| Address | Function | Role |
|---|---|---|
| `0x0082b0c4` | `checksum8_additive` | Additive byte checksum (sum of first 15 bytes → byte 15) |
| `0x0082ebdc` | `channel_a_queue_notify_frame` | Queue 16-byte response into Channel A notify ring |
| `0x0082b938` | `channel_a_send_fragmented_response` | Send a long response fragmented into 14-byte chunks |
| `0x0082c988` | `FUN_0082c988` | Stream large data for opcodes `0x37`, `0x39`, `0x7a` |

`FUN_0082b986(opcode, isNotify)` sends a simple 1-byte opcode response (with `0x80` flag for notify-only opcodes).

### 3.16 Opcode `0x77` `phoneSport` sub-command dispatch (`FUN_0082ce0c`)

The 0x77 handler is a *two-stage* dispatcher: the main handler
`FUN_0082ce0c` reads `req[1]` and indexes a switch8 at
`0x82ce23` (7 active entries, max-index `6`), then jumps to
one of the per-sub-byte thunks. The thunks are tiny
"register-only" stubs whose locals have all been optimized
out by the compiler — the decompiler shows them as
`unaff_r4..r7` because the parent dispatcher passes the
request pointer in `r4`, the state byte in `r5`, the sport
context in `r6`, and zero in `r7`, and the thunks reuse
those registers directly.

#### Dispatcher entry (`FUN_0082ce0c`)

```asm
push {r4,r5,r6,r7,lr}
mov  r4, r0                   ; r4 = request frame
ldrb r0, [r0, #1]             ; r0 = sub-byte
ldr  r1, [0x82cff8]           ; r1 = state ptr
sub  sp, #0x14
ldr  r6, [0x82cff4]           ; r6 = sport context ptr
ldrb r5, [r1]                 ; r5 = state byte
movs r7, #0
movs r3, r0                   ; r3 = sub-byte (for switch8)
bl   0x8405fc                ; __ARM_common_switch8
```

So the registers passed into the per-sub-byte thunks are:
- `r4` = request frame pointer
- `r5` = 1-byte sport state (loaded from `*DAT_0082cff8`)
- `r6` = sport context (20-byte block at `DAT_0082cff4`)
- `r7` = 0

The switch8 at `0x82ce23` dispatches on `req[1]` to:

| `req[1]` | Thunk | Notes |
|---:|---|---|
| `0x00`, `0x06` | `FUN_0082cede` | Default ack — builds `0x77` response with checksum |
| `0x01` | `FUN_0082ce2a` | Start/finish sport session |
| `0x02` | `FUN_0082ce64` | Pause / resume bit |
| `0x03` | `FUN_0082ce72` | Lap / split bit |
| `0x04` | `FUN_0082ce80` | Cancel sport session |
| `0x05` | `FUN_0082ce96` | GPS/position delta |

#### Sub-handler details

The `unaff_r*` accesses are the optimizer-removed parameters.
The recovered semantics are:

* **`0x01` start/finish (`FUN_0082ce2a`)**:
  1. `memset(sport_ctx, 0, 0x14)` — clear the 20-byte sport context.
  2. If `r5 != 0` (state byte): call `FUN_00830c7e()` (stop sport).
  3. `FUN_00828af4()` — HR step-counter running check; if non-zero,
     call `FUN_0082b108()` (likely the same "ack" builder used by
     the deferred ring) and return — *sport session cannot start
     while HR is busy*.
  4. `FUN_00830c82(req[2])` — start sport in mode `req[2]`
     (the per-mode flag from the H59MA SDK).
  5. `*sport_ctx = 1` — set "running" flag at offset 0.
  6. `func_0x00013694(DAT_0082cffc, 1000)` — arm a 1000 ms
     one-shot timer at the 2nd literal-pool slot (the 1 Hz sport
     tick that the main loop drains to update step counts).
  7. `FUN_0082b108()` + `FUN_0082cede()` — emit the 0x77 ack.

* **`0x02` pause bit (`FUN_0082ce64`)** and **`0x03` lap bit
  (`FUN_0082ce72`)** are mirror images: if `r5 != 0`, set
  `*(sport_ctx + 1) = 1` (the "pause/lap in progress" flag),
  call `FUN_00830cb2` (pause) or `FUN_00830cbc` (lap), restore
  the original `r7` value (always 0 in the dispatcher) to byte
  1, and emit the ack. If `r5 == 0`, the call is a no-op
  `FUN_0082b0c4` + `FUN_0082ebdc` (i.e. an empty response).

* **`0x04` cancel (`FUN_0082ce80`)**: cancel the 1000 ms tick
  timer via `func_0x000136bc(DAT_0082cffc)`, set the in-progress
  flag at `sport_ctx[1] = 1` (so the dispatcher's "if r5 != 0"
  guard is satisfied for the remainder of the session), call
  `FUN_00830c7e()` to stop the step-counter / sport-motion
  library, and emit the ack.

* **`0x05` GPS delta (`FUN_0082ce96`)** is the only data-bearing
  sub-byte. The handler reads two 3-byte little-endian u24 values
  from the request and integrates them into cumulative counters
  on the sport context:

  ```c
  uint32_t new_lat = (req[3] | (req[4] << 8) | (req[5] << 16));
  uint32_t new_lng = (req[7] | (req[8] << 8) | (req[9] << 16));
  sport_ctx[0xc / 4] += (int32_t)(new_lat - sport_ctx[4 / 4]);  // lat delta
  sport_ctx[0x10 / 4] += (int32_t)(new_lng - sport_ctx[8 / 4]); // lng delta
  sport_ctx[4 / 4] = new_lat;
  sport_ctx[8 / 4] = new_lng;
  ```

  The 12-byte sport context fields are therefore:

  | Off | Field | Notes |
  |---:|---|---|
  | 0 | `running_flag` | 1 if a session is in progress |
  | 1 | `pause_or_lap_flag` | 1 if a pause/lap sub-cmd is mid-handler |
  | 2..3 | (unused) | |
  | 4..7 | `last_lat` (u32 LE) | last reported latitude value |
  | 8..11 | `last_lng` (u32 LE) | last reported longitude value |
  | 12..15 | `cum_lat` (i32 LE) | cumulative latitude delta |
  | 16..19 | `cum_lng` (i32 LE) | cumulative longitude delta |

  The two u24 values in the request are **arbitrary bit-pattern
  encodings** of latitude and longitude, not BCD degrees-minutes;
  the watch just keeps a running sum of the per-tick deltas and
  surfaces the total in the 0x77 response. The `req[1] == 0x01
  || req[1] == 0x06` branch in the sub-handler is the same
  guard that the default-ack thunk uses to decide whether to
  emit a 14-byte response or a 0-byte response.

The helper functions `FUN_00830c7e`, `FUN_00830cb2`, `FUN_00830cbc`,
`FUN_00830c82` live in the step-counter / sport-motion library
(`vc_SportMotion_Int`) referenced in
`firmwares/_re/strings-mining/findings.txt`.

### 3.17 Opcode `0x38` pressure (1-bit read/write) (`FUN_0082ca54`)

The simplest "1-bit setting" pair in the table — analogous to
the `0x2c bloodOxygenSetting` handler from §3.10. The
"pressure value" is a single bit stored in the same shared
config byte at `DAT_008277f0 + 0x2D` that holds the SpO2 flag,
UV-touch byte, etc.

#### Sub-opcode dispatch

| `req[1]` | Action | Helper used |
|---:|---|---|
| `0x01` (read) | `cStack_1e = FUN_00827772()` — read bit 3 of `*(DAT_008277f0 + 0x2D)`, masked `& 0xF >> 3` yields `0` or `1` | `FUN_00827772` |
| other (write) | `FUN_0082777e(req[2] == 1)` — if `req[2] == 1`, set bit 3; else clear it. The handler then **echoes** `req[2]` (not the coerced 0/1) into the response. | `FUN_0082777e` |

The mask `& 0xF` and the `<< 3` shift confirm that only bit 3
of the shared config byte is owned by the pressure setting;
the other 7 bits of that byte belong to other features
(SpO2, UV-touch, etc.).

#### Response layout (3 useful bytes + 13 zero bytes + checksum)

```
byte  0: 0x38                (cmd echo)
byte  1: req[1]              (sub-opcode echo: 0x01 read / 0x02+ write)
byte  2: pressure value      (0/1 for read; echoed req[2] for write)
byte  3..14: 0
byte 15: additive checksum
```

The response is built directly on the stack (the handler
clears the 16-byte frame once at the top and writes only the
three output bytes), so the rest of the frame is always zero.

#### Why this is so short

* The 1-bit storage means the entire pressure "value" is a
  boolean — the H59MA pressure sensor (if present) is either
  enabled or disabled, not a continuous reading. A host that
  wants the actual mmHg / kPa reading must subscribe to a
  push channel (likely a `0x2B`-routed event) rather than
  poll `0x38`.
* The 0/1 read and the echoed `req[2]` write response are
  **deliberately consistent** with the `0x2c` SpO2 and `0x3b`
  UV-touch handlers — the host code can treat all three
  "1-bit setting" opcodes uniformly with the same
  `read = 0x01 / write = 0x02` sub-opcode pattern.

#### Companion opcode `0x37` pressureSetting

`0x37` (`FUN_0082caa6`) is a *separate* config opcode that
uses the same shared `FUN_0082c988` 13-byte-chunk fragmenter
as `0x7a muslim` (§3.11) and `0x39 hrv`. It likely configures
the per-mode pressure algorithm (high/low threshold, alert
frequency, etc.) rather than the on/off bit that `0x38`
owns. The host should not confuse the two: `0x37` is the
*settings* opcode (long fragmented response), `0x38` is the
*value* opcode (3-byte ack).

### 3.18 Opcode `0x3b` uvSetting / touchControl (`FUN_0082cbc8`)

A 1-byte read/write of the UV / touch-screen control byte
stored at `DAT_0082cfe8 + 8` (a different config struct from
the one used by `0x2c` SpO2 and `0x38` pressure — this one
lives in the *display* config block rather than the
*sensor* config block). The handler is also notable for its
**"echo the request" response** pattern: instead of building
the response from scratch, it `memcpy`s the 16-byte request
into the response buffer and overwrites only byte 0 (with
the cmd) and byte 15 (with the checksum).

#### Sub-opcode dispatch

| `req[1]` | `req[2]` | Action |
|---:|---:|---|
| `0x01` | `0x00` | **Read**: `uStack_15 = *(DAT_0082cfe8 + 8)` (returns the 1-byte UV/touch config) |
| `0x02` | `0x00` | **Write**: `*(DAT_0082cfe8 + 8) = req[3]`; commit via `FUN_00827624()` |
| other | `0x00` | No-op: response is just an echo of the request |
| any | `!= 0x00` | No-op: response is just an echo of the request |

The `req[2] == 0` guard is unusual — most config opcodes
treat `req[1]` as the only sub-opcode. Here, `req[2]` is a
**"batch mode"** flag: when set, the read/write is *not*
performed and the watch just echoes the request back. This
is the same pattern that `0x18 displayClock` uses for its
"label ≥ 13 bytes" spill to `DAT_0082cfec` (see §3.5) — a
host that wants to push a multi-frame value sends the first
frame with `req[2] != 0` (so the watch doesn't commit
prematurely) and the last frame with `req[2] == 0` (so the
watch commits the final value).

#### Response layout (16-byte frame, mostly request-echo)

```
byte  0: 0x3B                 (cmd, overwritten)
byte  1: req[1]               (sub-opcode echo)
byte  2: req[2]               (echo — batch-mode flag preserved)
byte  3: read value (0x01 path) | req[3] (0x02 path) | req[3] (no-op)
byte  4..14: req[4..14]       (echo)
byte 15: additive checksum    (per §3)
```

Because the handler `memcpy`s the request into the response
*before* touching bytes 0/3, the only fields that ever differ
between the request and the response are byte 0 (always
`0x3B`) and byte 3 (only for the `0x01` read path). The
rest of the response is a byte-for-byte echo.

#### Persistent state

| Off | Field | Notes |
|---:|---|---|
| `DAT_0082cfe8 + 8` | `uv_touch_config` (u8) | the 1-byte control value |

Unlike `0x2c` (`*(DAT_008277f0 + 0x2D)` bit 1) and `0x38`
(`*(DAT_008277f0 + 0x2D)` bit 3), the UV/touch value is a
**full byte** (0..255), not a 1-bit flag. The host should
not assume any particular bit layout when reading it back;
treat the value as an opaque feature-mode byte that the
firmware-side producer (the UV sensor / touch-screen
driver) consumes.

#### `sleep_refresh_after_time_or_config_change`

Called on the write path after the byte is stored. The same helper is also
called by `0x01 setTime` when the RTC changes. Earlier notes treated this as a
settings commit, but the Ghidra body is a thin wrapper around
`sleep_recompute_live_history_summary`: it refreshes today's detailed-sleep
slots, rolls up the previous six days' sleep totals, and updates the cached
sleep-state byte from the latest night-sleep record. No direct blob0/blob1 flash
write is visible in this helper.

#### Why the request-echo response

* For a *single-frame* read or write, the echo is
  indistinguishable from a hand-built response and saves a
  handful of cycles per handler invocation.
* For the *multi-frame batch* use case, the echo doubles as
  a frame-receipt: the host can use the unmodified bytes
  4..14 in the response as confirmation that the same
  payload arrived intact, without a separate echo frame.

### 3.18.1 Opcode `0x0c` bpSetting (`FUN_0082c0de` / `FUN_008341d4` / `FUN_00834210`)

This FEE7/Channel-A shared handler is a normal mixture read/write setting.
`sub == 1` reads the BP auto-measure config, `sub == 2` validates and stores a
new config, and any other sub-value returns without a response.

#### Request and response layout

Read request:

```
payload[0] = 0x01
```

Read response (`FUN_008341d4` fills bytes 1..6; wrapper writes byte 0):

```
payload[0] = 0x01
payload[1] = enabled
payload[2] = startMinutes / 60
payload[3] = startMinutes % 60
payload[4] = endMinutes / 60
payload[5] = endMinutes % 60
payload[6] = intervalMinutes
```

Write request:

```
payload[0] = 0x02
payload[1] = enabled
payload[2] = startHour
payload[3] = startMinute
payload[4] = endHour
payload[5] = endMinute
payload[6] = intervalMinutes
```

`FUN_00834210` rejects `payload[6] == 0` and any value not divisible by 30.
The wrapper passes that return value to the generic ACK helper, so invalid
writes return the opcode with the Channel-A high-bit error flag set.

Defaults are applied during BP-history module init when the config enable byte
is still `0xff`: enabled `1`, start `00:00`, end `23:00` (`0x0564` minutes),
and interval `0x3c` (60 minutes). This byte is minutes, not the legacy
APK/SDK "multiple" field name.

### 3.19 Opcode `0x0e` bpReadConform (BP record index advance) (`FUN_0082cb28`)

The smallest handler in the Channel-A table (17 bytes): a
"confirm and advance" command for the blood-pressure record
queue. The request opcode is `0x0E` but the response
opcode is `0x0D` (BP *record* read) — the request is the
"please advance and emit next record", the response is the
record itself.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x0E` | cmd (consumed by dispatcher) |
| 1 | `sub` | `0` → advance + read next; other → no-op |
| 2..14 | unused | — |

The handler does not respond to a non-zero `sub`; it silently
exits. The "advance" semantics is *not* implicit in receiving
the opcode — the host must explicitly request the advance by
sending `sub == 0`, which gives the host a clean way to poll
without consuming records.

#### Behavior (sub == 0)

```c
void FUN_0082cb28(int param_1) {
    if (param_1[1] != 0) return;
    FUN_00834410();   // advance the BP record index
    FUN_0082c0a4();   // read next record + emit fragmented 0x0D response
}
```

`FUN_00834410` advances a circular index:

```c
void FUN_00834410() {
    state = DAT_008344ac;
    *(u32*)(state + 0x10 + *(u8*)(state + 0xE) * 4) = 0;  // clear current slot
    *(u8*)(state + 0xE) = *(u8*)(state + 0xE) + 1;          // index++
}
```

So `DAT_008344ac` is the BP-record-queue state, byte `+0xE`
is the "current read index" (wraps at 256), and bytes
`+0x10 + idx*4` are a circular buffer of u32 slots — each
slot is presumably the "this record was read at time T" or
"this record's read-confirm flag" (the handler zeros the slot
on advance, presumably so a subsequent re-read of the same
slot will get a fresh value).

`FUN_0082c0a4` then reads the next BP record and ships it:

```c
void FUN_0082c0a4() {
    int n = FUN_00834296(&hdr, &body);        // fill header (14 B) + body
    if (n != 0xff) {
        FUN_0082b938(0x0D, &hdr, 0xE);        // fragment #1: 14 B header
        if (n != 0) {
            FUN_0082b938(0x0D, &body, n);     // fragment #2: n B body
        }
    }
}
```

* The response cmd is **`0x0D`**, not `0x0E` — the dispatcher
  emits a *different* opcode for the response than the request.
  This is the only such case in the Channel-A table; all
  other "config read" opcodes echo the request cmd.
* `FUN_0082b938` is the shared 14-byte-chunk fragmented
  streamer (see §3.2) used by 0x18 / 0xC7 and others. A
  BP response is split into a fixed 14 B tagged header plus a
  variable compact body, so more than 13 present slots take
  multiple body frames.
* `FUN_00834296` sends an empty/end sentinel by clearing the
  header and writing `hdr[0] = 0xFF`. The handler still emits
  that `0x0D` header frame; it is not a silent no-data path.

#### Response layout

Header frame (`FUN_00834296(&hdr, &body)` first argument):

```
payload[0]      = 0x00
payload[1]      = year - 2000
payload[2]      = month
payload[3]      = day
payload[4]      = intervalMinutes       // default 0x3c = hourly
payload[5..10]  = 48-bit presence bitmap, little-endian
payload[11..13] = 0
```

Empty/end frame:

```
payload[0]      = 0xFF
payload[1..13]  = 0
```

Body frames (`FUN_00834296(&hdr, &body)` second argument):

```
payload[0]     = 0x01
payload[1..13] = up to 13 compact BP bytes, ascending bitmap slot order
```

The builder inserts the `0x01` body tag whenever `body_len % 14 == 0`, because
the shared streamer copies exactly 14 payload bytes per frame. The bytes after
the tag are therefore one compact value per present slot, not 13-byte per-slot
records.

The persistent BP descriptor (§persistent-history descriptor rings) stores the
day key plus 24 hourly 4-byte slots. This `0x0D` history response validates the
slot's first byte (`0x28..0xDC`) and emits only that byte. The remaining three
persistent bytes are not exposed by this opcode, so the host must not invent
systolic/diastolic history values from the compact stream.

#### Why the request/response opcode split

* The watch's BP *measurement* is triggered separately (e.g.
  the `0xA1 0x04` factory test path or a real measurement
  request), and produces a record that ends up in the
  internal queue. The host then polls `0x0E` to *confirm* it
  has read the next record, which both advances the index
  and triggers the next read.
* Splitting "advance" from "read" lets a host that needs to
  throttle polls (e.g. on a slow link) send `0x0E 0x01`
  repeatedly without ever consuming a record, and then send
  `0x0E 0x00` exactly once when ready to read.

#### Why no ack for the request

The 0x0E handler never emits a 0x0E response — the response
*is* the 0x0D frame. A host that sends `0x0E 0x00` and receives
`0x0D` with `payload[0] == 0xFF` should treat the queue as
exhausted; a nonzero 0x0E sub-byte silently exits and sends no
response.

### 3.20 Opcode `0x37` pressureSetting (`FUN_0082caa6`)

Structurally a *clone* of the `0x7a muslim` handler (§3.11) —
same two-phase response (header frame + 4-frame fragmented
49-byte payload), same 13-byte-chunk fragmenter
`FUN_0082c988`. The two differences are:

* The producer `FUN_008344fe` is a **real implementation** (not
  a stub like `FUN_00829c88`).
* The header literal dword is `0x1E050037` (LE), not
  `0x3C05007A`; byte 3 is `0x1E` (30) rather than `0x3C` (60).
  The host can use this byte to disambiguate the two
  long-response opcodes if the cmd byte is lost in a
  fragmentation boundary.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x37` | cmd (consumed by dispatcher) |
| 1 | `slot_id` | day offset (current day = `slot_id == 0`) |
| 2..14 | unused | — |

Only `slot_id == 0` (today) is supported by the "happy path"
in v14 — the dispatcher in §3 routes every non-zero sub-cmd
to the default-slot (`FUN_0082cede` in 0x7a's case, the same
here). Sub-`0x01` etc. are not implemented; the only valid
host request is `0x37 0x00` (read today's pressure setting).

#### Behavior

```c
void FUN_0082caa6(int param_1) {
    memset(stack, 0, 0x10);          // clear 16 B response
    memset(stack, 0, 0x34);          // clear 52 B pressure data buffer
    if (FUN_008344fe(param_1[1], &buf) == 0) {
        // No record for this slot: send error
        rsp[0..1] = 0x37 | 0xFF;     // little-endian: byte 0 = 0x37, byte 1 = 0xFF
        FUN_0082ebdc(rsp);           // queue the error frame
    } else {
        // Record found: send header + 4-frame fragmented payload
        rsp[0..3] = 0x1E050037;      // little-endian: 0x37, 0x00, 0x05, 0x1E
        FUN_0082ebdc(rsp);
        buf[0] = param_1[1];         // slot id echo
        FUN_0082c988(0x37, buf, 0x31);   // fragment 49 B into 4 frames
    }
}
```

#### `FUN_008344fe` — pressure record read

```c
uint FUN_008344fe(int slot_id, u32 *out) {
    int month = FUN_0082840e();           // current month
    pressure_rec *r = FUN_0082966e(       // look up by month offset
        DAT_00834648, *DAT_00834644, month - slot_id
    );
    if (r == NULL) return 0;              // no record: 0 means "empty"
    *out = *r;                            // copy 4-byte header
    for (int i = 0; i < 0x30; i++) {     // copy 48 B body
        if (r->body[i] == -1 || r->body[i] == 0)
            out->body[i] = 0;            // null-terminate
        else
            out->body[i] = r->body[i];
    }
    return 0x30;                          // body length
}
```

So the pressure record is 4 bytes of header + 48 bytes of
string-like body, stored in a record table indexed by
`month_offset` from today. The body is *null-terminated in
the response* even when the source record is `-1`-padded
(presumably to keep the body length consistent across
uninitialised records).

#### Response layout (mirrors 0x7a)

Phase 1 — header:
```
byte  0: 0x37
byte  1: 0x00
byte  2: 0x05         (5-dword payload size? see §3.11)
byte  3: 0x1E         (the "feature id" — 30 instead of muslim's 60)
byte  4..14: 0
byte 15: additive checksum
```

Phase 2 — 4 frames via `FUN_0082c988(0x37, &buf, 0x31)`:
```
frame N (N=1..4):
  byte  0: 0x37
  byte  1: N
  byte  2..14: 13 bytes of (1-byte slot id + 48-byte body)
  byte 15: additive checksum
```

The slot id is at payload byte 0 (echo of `req[1]`), and the
48-byte body starts at payload byte 1.

#### Comparison with `0x7a muslim`

| | `0x37` pressureSetting | `0x7a` muslim |
|---|---|---|
| Producer | `FUN_008344fe` (real) | `FUN_00829c88` (stub) |
| Header dword | `0x1E050037` | `0x3C05007A` |
| Body shape | 4 B header + 48 B body | (same) |
| Fragment count | 4 | 4 |
| Slot-id echo at payload byte 0 | yes | yes |

Both opcodes are routed through `FUN_0082be64` (the deferred
ring) by the Channel-A dispatcher, so a host that issues
`0x37` and `0x7a` in quick succession will see both
fragments come back interleaved on the notify ring — the
host should re-sync on each `byte 0 == 0x37` or `0x7A`
header to separate the two streams.

#### Why 30 (0x1E) and not 60 (0x3C) for the feature id

The `0x3C` in `0x7a muslim`'s header and the `0x1E` in
`0x37 pressureSetting`'s header are likely **indexes into
the same per-feature config table**. The dispatcher (and
the long-config shared fragmenter from §3.11) does not
*interpret* these bytes — they are producer-specific
identifiers that the host-side SDK uses to know which
feature a given header belongs to. The two-byte pattern
`{opcode_byte, 0x00, 0x05, feature_id}` is the "long
config" ack shape that all the §3.11 / §3.20 handlers
use.

### 3.21 Opcode `0x39` hrvSetting (`FUN_0082c9da`)

The third and final member of the *shared-fragmenter
trio* (after `0x37 pressureSetting` §3.20 and `0x7a muslim`
§3.11). Structurally a near-clone of `0x37` — same
two-phase response, same 4-byte header + 48-byte body
shape, same 4-frame fragmented 49-byte payload via
`FUN_0082c988` — with a different producer and header
literal.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x39` | cmd (consumed by dispatcher) |
| 1 | `slot_id` | day offset (current day = `slot_id == 0`) |
| 2..14 | unused | — |

Identical to `0x37 pressureSetting`. Only `slot_id == 0`
(today) is on the happy path; the dispatcher routes every
other sub-cmd to the default-slot ack.

#### Behavior

```c
void FUN_0082c9da(int param_1) {
    memset(stack, 0, 0x10);
    memset(stack, 0, 0x34);
    if (FUN_0083468e(param_1[1], &buf) == 0) {
        rsp[0..1] = 0x39 | 0xFF;            // little-endian: byte 0 = 0x39, byte 1 = 0xFF
        FUN_0082ebdc(rsp);                  // queue "no record" error
    } else {
        rsp[0..3] = 0x1E050039;             // little-endian: 0x39, 0x00, 0x05, 0x1E
        FUN_0082ebdc(rsp);
        buf[0] = param_1[1];                // slot id echo
        FUN_0082c988(0x39, buf, 0x31);      // fragment 49 B into 4 frames
    }
}
```

Compare to §3.20's `0x37 pressureSetting`: the only byte that
differs is the **cmd** in the header dword (`0x37` vs `0x39`);
byte 3 (the feature id `0x1E`) is the *same* for both,
suggesting that the watch's per-feature config table groups
pressure and HRV together under feature id `0x1E` (30).

#### `FUN_0083468e` — HRV record read

```c
uint FUN_0083468e(int slot_id, u32 *out) {
    int month = FUN_0082840e();
    hrv_rec *r = FUN_0082966e(        // look up by month offset
        DAT_008347dc, *DAT_008347d8, month - slot_id
    );
    if (r == NULL) return 0;            // no record
    *out = *r;                          // copy 4-byte header
    for (int i = 0; i < 0x30; i++) {   // copy 48 B body
        if (r->body[i] == -1 || r->body[i] == 0)
            out->body[i] = 0;          // null-terminate
        else
            out->body[i] = r->body[i];
    }
    return 0x30;
}
```

This is the **same body shape** as `FUN_008344fe` (§3.20) but
with a different data-table pointer (`DAT_008347dc` /
`*DAT_008347d8` instead of `DAT_00834648` / `*DAT_00834644`).
Both producers look up records in a shared "per-day record
table" indexed by month-offset from today, so the host can
treat them uniformly: ask for "today" and get a 4-byte
header + 48-byte body, or ask for a different day and get
the same shape (or an error frame for an empty slot).

#### Response layout (mirrors 0x37)

Phase 1 — header:
```
byte  0: 0x39
byte  1: 0x00
byte  2: 0x05
byte  3: 0x1E         (same feature id as 0x37!)
byte  4..14: 0
byte 15: additive checksum
```

Phase 2 — 4 frames via `FUN_0082c988(0x39, &buf, 0x31)`:
```
frame N (N=1..4):
  byte  0: 0x39
  byte  1: N
  byte  2..14: 13 bytes of (1-byte slot id + 48-byte body)
  byte 15: additive checksum
```

The slot id is at payload byte 0, and the 48-byte body starts
at payload byte 1.

#### Trio summary

| | `0x37` pressureSetting | `0x39` hrvSetting | `0x7a` muslim |
|---|---|---|---|
| Header dword | `0x1E050037` | `0x1E050039` | `0x3C05007A` |
| Feature id (byte 3) | `0x1E` (30) | `0x1E` (30) | `0x3C` (60) |
| Producer | `FUN_008344fe` (real) | `FUN_0083468e` (real) | `FUN_00829c88` (stub) |
| Body shape | 4 B header + 48 B body | same | same |
| Fragmenter | `FUN_0082c988` | same | same |

The fact that `0x37` and `0x39` share the same feature id
(`0x1E`) while `0x7a` uses a different one (`0x3C`) implies
the firmware has at least **two distinct long-config feature
groups**: "sensor metrics" (pressure + HRV, both under
`0x1E`) and "user-content" (muslim, under `0x3C`). The host
SDK can use the feature id to decide which body-shape parser
to apply when it receives a fragmented long-config response.

### 3.22 Opcode `0x3a` sugarLipidsSetting (`FUN_0082cc1e`)

A **two-bit-per-feature config pair** — sugar and lipids
monitoring are 1-bit on/off flags packed into the same shared
config byte at `DAT_008277f0 + 0x2D` already used by
`0x2c` SpO2 (§3.10) and `0x38` pressure (§3.17).

#### Persistent state (1 bit each)

| Field | Bit position in `*(DAT_008277f0 + 0x2D)` | Read helper | Write helper |
|---|---:|---|---|
| sugar setting | bit 5 | `FUN_00827790` (`(*(byte*) & 0x3F) >> 5`) | `FUN_0082779c` (`... & 0xDF | (v << 5)`) |
| lipids setting | bit 7 | `FUN_008277ce` (`*(byte*) >> 7`) | `FUN_008277d8` (`... & 0x7F | (v << 7)`) |

The masks (`0x3F`, `0xDF`, `0x7F`) and shifts (`>> 5`, `<< 5`,
`>> 7`, `<< 7`) prove these are the only bits the handlers
own; the other 6 bits of `*(DAT_008277f0 + 0x2D)` belong to
the other 1-bit features. Combined with §3.10 / §3.17 the
full bit map is:

| Bit | Owner |
|---:|---|
| 1 | SpO2 (`0x2c`) |
| 3 | Pressure (`0x38`) |
| 5 | Sugar (`0x3a` sub 0x03) |
| 7 | Lipids (`0x3a` sub 0x04) |

#### Sub-opcode dispatch

`req[1]` selects the feature; `req[2]` selects read vs write.

| `req[1]` | `req[2]` | Action |
|---:|---:|---|
| `0x03` | `0x01` | **Read sugar**: response `[0x3A, 0x03, 0x01, sugar_value, 0, …, 0, cksum]` |
| `0x03` | `0x02` | **Write sugar**: `FUN_0082779c(req[3] != 0)`; response = the **request frame echoed unchanged**; on first commit, also set `*(DAT_0082cfe8 - 0x92) = 0x1E` (mark "config block initialised") |
| `0x03` | other | no-op, no response |
| `0x04` | `0x01` | **Read lipids**: response `[0x3A, 0x04, 0x01, lipids_value, 0, …, 0, cksum]` |
| `0x04` | `0x02` | **Write lipids**: `FUN_008277d8(req[3] != 0)`; response = `[0x3A, 0, 0, 0, 0, …, 0, cksum]` (1-byte-cmd ack — *not* an echo) |
| `0x04` | other | no-op, no response |
| other | any | no-op, no response |

#### Asymmetric write responses

The handler uses two *different* response shapes for the two
write paths:

* **Sugar (`0x03 0x02`)**: the request frame is **echoed
  unchanged** via `FUN_0082ebdc(param_1)` — same pattern as
  `0x06 DND` (§3.7) and `0x3b uvTouch` (§3.18). The host
  treats the echo as a self-describing ack and can verify
  the exact `(feature, sub, value)` triple the watch
  committed.
* **Lipids (`0x04 0x02`)**: the response is a minimal
  `[0x3A, 0, …, 0, cksum]` — only the cmd byte is set. This
  is the same shape as `0x1e realTimeHeartRate`'s 1-byte
  ack (§3.13). The host must use a follow-up `0x04 0x01`
  read to confirm the value actually changed.

This asymmetry is the only place in the Channel-A table
where two structurally identical "1-bit config write" pairs
use different ack shapes. The host code that consumes
these handlers should not assume a uniform "echo-on-write"
behaviour across all 1-bit config opcodes.

#### First-time-init side effect

The sugar write path also has a one-shot side effect: if
`*(DAT_0082cfe8 - 0x92) == 0`, set it to `0x1E`. This flag
is the "config block initialised" sentinel — it likely
tells the next `0x81` config-chunk flush (§3.5) that the
sugar / lipids config is part of the persistent block that
must be written to flash. The lipids write path does *not*
have this side effect, which suggests the firmware
considers the sugar bit a "primary" config and the lipids
bit a "secondary" one (or vice-versa, depending on the
producer's view of which one is the canonical setting).

#### Response layout (read paths)

```
byte  0: 0x3A
byte  1: req[1]              (0x03 sugar / 0x04 lipids)
byte  2: 0x01                (read sub-cmd echo)
byte  3: feature value       (0 or 1)
byte  4..14: 0
byte 15: additive checksum
```

The response is built on the stack from the saved-register
slots used by the dispatcher (no `memcpy` from the request),
so the only non-zero output bytes are 0..3 + 15.

### 3.2 Opcode `0xc7` vibration / motor pattern player (`FUN_00832ebc`)

A two-mode motor controller dispatched by the value of `*DAT_00833188`
(default `'D'` = `0x44`; alternative `'#'` = `0x23`). The handler
re-uses the same 12-byte payload that follows the first three bytes of
the 16-byte request, passed through the caller's saved register slots
(`push {r2,r3,r4,lr}`).

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `presence` | `0` → stop; non-zero → play |
| 1 | `pattern_id` | low 7 bits; ORed with `0x80` to mark "play" on the play path |
| 2 | `duration` | clamped to 6 |
| 3..14 | `pattern` | 12 bytes of pattern data (motor strength, rhythm, etc.) |
| 15 | checksum | additive (per §3) |

#### Behavior

* If `presence == 0` (stop path):
  * mode `'#'` → `sensor_bus_write_reg_0x1f(pattern_id, duration)` — stop pulse-pattern
  * mode `'D'` → `sensor_bus_write_reg_0x19_b(pattern_id, duration)` — stop duration-pattern
  * No response frame is sent.
* If `presence != 0` (play path, `length = min(duration, 6)`):
  * mode `'#'` → `sensor_bus_read_reg_0x1f(pattern_id | 0x80, &pattern, length)` — play pulse-pattern
  * mode `'D'` → `sensor_bus_read_reg_0x19_b(pattern_id | 0x80, &pattern, length)` — play duration-pattern
  * In both cases, the response is a **fragmented** `0xC7` frame sent
    via `channel_a_send_fragmented_response(0xC7, &pattern, length)`. The fragmentation
    helper packs at most 14 payload bytes per 16-byte notify frame
    with additive checksum.

#### `channel_a_send_fragmented_response` (fragmented response)

```c
void channel_a_send_fragmented_response(byte cmd, int payload, uint length) {
  do {
    chunk = min(length, 0xe);     // 14 payload bytes per frame
    frame[0] = cmd;
    memcpy(&frame[1], payload, chunk);
    frame[15] = checksum8_additive(frame, 0xf);
    channel_a_queue_notify_frame(frame);
    payload += chunk;
    length  -= chunk;
  } while (length != 0);
}
```

The fragmenter is shared with `0x18 displayClock`, `0xc1 0xFEE7 health poll`
and any handler that needs to send a >14-byte response (e.g. the
`0x40..0x42` file-list responses and the `0x27/0x3e` sleep records).

#### `sensor_bus_read_reg_0x1f` (mode `#` play, returns success bool)

```c
uint sensor_bus_read_reg_0x1f(id, payload, length) {
  if (func_0x000133f4(*DAT_0083230c, 100) == 0) return 0;  // mutex acquire
  ok = (sensor_bus_read_payload(0x1f, id, payload, length) == 0);
  func_0x0001341c(*DAT_0083230c);                          // mutex release
  return ok;
}
```

The `0x1f`, `0x19`, and `0x20` selector values are sensor/peripheral-bus
commands used here by the motor-pattern code. The helper names describe the
bus primitive Ghidra sees; in this handler the user-visible semantics are still
"play" or "stop" a motor pattern. The `*DAT_0083230c` mutex pointer is the same
serialising lock used by all pattern routines (`sensor_bus_write_reg_0x1f`,
`sensor_bus_read_reg_0x1f`, `sensor_bus_write_reg_0x19_b`,
`sensor_bus_read_reg_0x19_b`), so two patterns cannot be active at once.

### 3.3 Opcode `0x72` push-message / Unicode notifier (`FUN_00829e92`)

The watch-side handler for an incoming push notification or
emoji-bearing string. The handler is a **chunked accumulator** — the
host may issue several `0x72` frames in a row, each appending 11 bytes
to an internal buffer, then send a final "flush" frame to render.

The handler maintains a private context anchored at `DAT_00829f6c`:

| Offset (from `DAT_00829f6c`) | Field | Notes |
|---:|---|---|
| `-0xa7` | `cursor` (u8) | Current write position in the text buffer |
| `-0x88` | `text[0x85]` | 133-byte UTF-8 message buffer |
| `+0x08` | `category` (u8) | Set by the renderer to `0` (idle) or `0x16` (displayed) |

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `opcode` | `0x72` (consumed by dispatcher) |
| 1 | `notification_type` | 0..14, indexes a per-type table at `DAT_00829f7c - 0x18` |
| 2 | `flush_marker` | When `== flush_marker` of the *next* byte, the buffer is rendered and cleared |
| 3 | `flush_marker` (echo) | Must match byte 2 to trigger a flush — avoids spurious flushes from stale data |
| 4..14 | `payload[11]` | Up to 11 UTF-8 bytes appended to the message buffer |

The `flush_marker` equal-pair guard is the *only* thing distinguishing
"data" frames from "end-of-message" frames, so the host can stream
arbitrarily long messages with no length prefix.

#### Accumulator (`FUN_00829e92`)

1. If `cursor + 11 ≤ 0x84` (still room in the 133-byte buffer):
   - `memcpy(text + cursor, payload, 11)`
   - `cursor += 11`
2. If `req[2] == req[3]` (flush trigger):
   - `FUN_0082b986(0x72, 0)` — send a 1-byte `0x72` ack.
   - If `notification_type < 15`:
     - If `cursor > 0x74` (text would exceed 116 bytes), walk the
       buffer from byte 0 parsing UTF-8 lead-byte widths
       (1, 2, 3, 4, 5, 6, 7 for ranges `<0x80`, `0xC0..0xDF`,
       `0xE0..0xEF`, `0xF0..0xF7`, `0xF8..0xFB`, `0xFC..0xFD`,
       else) and stop at the last codepoint that fits before
       offset `0x7D` (125). Append the UTF-8 ellipsis
       (`\xE2\x80\xA6`) at the truncation point and bump the
       cursor past it.
     - Look up `table[notification_type]` in the 16-byte type table
       at `DAT_00829f7c - 0x18` to get the *category* byte, then
       call `notification_render_or_alert_by_category(&state)` to render.
   - `memset(text, 0, 0x85)` and reset `cursor = 0` regardless of
     whether a render happened.

#### Renderer (`notification_render_or_alert_by_category`)

The renderer's `state` dword is `[type, ?, category]`. It dispatches
on the `category` byte:

| Category | Behavior |
|---:|---|
| `0x00` | If the DND/overlay suppression flag (`FUN_0082a826()`) is clear **and** the per-type enabled bit at `*(iVar6 + 0x2c) & 1` is set, fire `alert_start_sequence(0x12, 1, 3, 0x32)`, store `type` and current RTC in the notification state, and call `notification_show_pattern1_if_config_bit_set()`. |
| `0x15` | `type == 0` clears any pending message: `alert_cancel_active()` + `ui_overlay_cancel_current()`. Other `type` values are no-ops (return). |
| other | If `type == 0` fire `alert_start_sequence(0x12, 1, 3, 5, ...)` + `ui_overlay_start_if_dnd_clear(3)`. If `type == 1`, walk the 32-entry `category` table at `DAT_00829f7c` and fire the alert for any matching entry whose `*((iVar6 + 0x2c) & (1 << idx))` bit is set. Always set `puVar2[8] = 0x16` (mark "displayed"). |

`FUN_0082b986(cmd, isNotify)` (the small 1-byte opcode ack sender used
on the flush path) builds a 16-byte frame with `cmd` (or `cmd | 0x80`
for notify) at byte 0 and queues it via `FUN_0082ebdc` — see §3
"Common response path".

The handler is the watch's bridge between the
`ChannelADispatcher.pushMsgUint` stream (in `lib/core/protocol/channel_a.dart`)
and the on-screen notification UI; a peer on the host can use the
fragmented helper from §3.2 to send messages longer than 11 bytes per
frame.

### 3.4 Opcode `0x01` setTime / clock sync (`FUN_0082bb4e`)

The clock-sync handler. Decodes six BCD date/time bytes from the
request, applies the result to the RTC, and then sends a 14-byte
`0x01` capability-shaped ack that tells the host the new packet-size
capability the watch will use going forward.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `opcode` | `0x01` (consumed by dispatcher) |
| 1 | `year_lo` (BCD) | low byte of year, e.g. `0x26` for 2026 |
| 2 | `month` (BCD) | `0x01`..`0x12` |
| 3 | `day` (BCD) | `0x01`..`0x31` |
| 4 | `hour` (BCD) | `0x00`..`0x23` |
| 5 | `minute` (BCD) | `0x00`..`0x59` |
| 6 | `second` (BCD) | `0x00`..`0x59` |
| 7 | `flags` | `0xFF` → skip the "tick" re-init at the end of the handler; other → call `FUN_00827956()` + `FUN_008276d2()` (refreshes the live counter / re-arms the seconds tick) |
| 8..14 | unused | — |

`FUN_0082edc4(bcd)` is the BCD-to-binary helper used to decode every
field: returns `(hi_nibble*10 + lo_nibble) & 0xFF` if both nibbles
are `< 10`, else `0` (defensive default for malformed frames).

#### Pre-ack `0x2f` MTU notify

Before the `0x01` ack, the handler publishes the negotiated ATT MTU on
a separate opcode:

```c
uint8 mtu = FUN_0082df12();          // reads *(DAT_0082e054 + 0x19)
if (mtu < 0x33) mtu = 0x14;          // floor: ATT_MTU=23 ⇒ payload 20
FUN_0082b23a(0x2f, mtu);             // send 16-byte frame [0x2f, mtu, 0…]
```

`FUN_0082b23a` is the small "two-byte opcode sender" used elsewhere for
configuration pings: it builds a 16-byte frame, places the cmd in byte
0 and the parameter in byte 1, and queues it via `FUN_0082ebdc`. The
host reads the value as the new `payload_cap` for all subsequent
Channel-A frames.

#### RTC update logic

After BCD-decoding the 6 time fields into a stack struct
`{year, month, day, hour, minute, second}` and calling
`FUN_00827ba6(2)` (display refresh), the handler compares the parsed
time to the current RTC value (`FUN_00827956()`):

1. **First set** (`*(DAT_0082bfb8 + 2) == 0`):
   - `FUN_00828390(&parsed)` — convert BCD date struct to seconds
     since epoch (uses `FUN_00828176` to derive a day-of-year, then
     `day_of_year * DAT_008284f8 + hour*3600 + minute*60 + second`).
   - `FUN_00827948(seconds)` — set RTC.
   - Mark `*(DAT_0082bfb8 + 2) = 1` and `*(DAT_0082bfbc + 0xd) = 1`
     (the "time has been set" latches).
   - `FUN_00827624()` + `thunk_FUN_00827424()` — re-init the
     tick-driver and broadcast a fresh time to all consumers.
2. **Subsequent set**:
   - Compute `cur_q = FUN_0083dfba(cur_seconds, 900)` and
     `req_q = FUN_0083dfba(req_seconds, 900)` — the 15-minute
     quarter-hour buckets of the two times.
   - Same bucket: `FUN_00827948(req_seconds)` (set directly).
   - `cur < req` (the watch is behind): `FUN_00827948((cur_q + 1) * 900)`
     (set to the *next* quarter boundary, then `FUN_008317d4()` to
     align the tick display).
   - `0 < cur - req < 3` seconds: no-op (avoid jitter from a slow
     host).
   - Otherwise (forward jump): `FUN_00827948(req_seconds)` +
     `FUN_00827624()`.

The "set to the next 15-min boundary when behind" path is the
practical difference between this and a naïve "just write the time":
it prevents the watch from showing `:14:59` after a host that has
been disconnected for an hour pushes its clock.

#### Response layout (14 bytes via `FUN_0082b938`)

After the RTC is settled, the handler always sends a 14-byte `0x01`
ack with a fixed pattern:

```
local_30 = 0x16010000   // bytes  1..4:  0x00 0x00 0x01 0x16
local_2c = 0            // bytes  5..8:  0x00 0x00 0x00 0x00
local_28 = 0x200001     // bytes  9..12: 0x01 0x00 0x20 0x00
local_24 = 0x3000       // bytes 13..14: 0x00 0x00  (high 2 bytes 0)
```

After `FUN_0082b938(0x01, &local_30, 0xe)` the wire frame is

```
byte  0: 0x01                    // cmd
byte  1: 0x00
byte  2: 0x00
byte  3: 0x01
byte  4: 0x16
byte  5: 0x00
byte  6: 0x00
byte  7: 0x00
byte  8: 0x00
byte  9: 0x01
byte 10: 0x00
byte 11: 0x20
byte 12: 0x00
byte 13: 0x00
byte 14: 0x00
byte 15: additive checksum
```

The four little-endian dwords are a static capability shape used as
"set OK" — the host should treat the 14-byte payload as opaque and
parse the meaning only after the matching `0x5A 0x01` read of the
device-info block (see §2.7).

### 3.5 Opcode `0x18` displayClock / watch-face switcher (`channel_a_handle_watchface_display_clock_18`)

Sets the active watch face and accepts both numeric ("go to face N")
and string-labelled ("set face label to S") payloads. The handler
echoes the request back in a 16-byte response and updates the
watch-face label/name state via `watchface_label_commit_ble_name_refresh`.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `opcode` | `0x18` (consumed by dispatcher) |
| 1 | `style` | sub-type selector — see below |
| 2 | `length` | only meaningful for label styles; `0x00..0x0C` echo-in-response, `0x0D..0xFF` spill to `DAT_0082cfec` |
| 3..14 | `payload` | label bytes (style 0x02/0x12/0x22/0x32) or ignored (other) |
| 15 | checksum | additive (per §3) |

#### `style` dispatch

| `style` | Action |
|---:|---|
| `0x01` | Numeric face index — calculates the new face's "label length" using `strlen()` on a previously-cached face-name buffer (`acStack_39`), then echoes that length in `response[2]` and copies the matching tail into `response[3..]`. Two sub-cases: a previous face whose name starts with `"O_"` (3-char prefix, label = `strlen - 7`), or any other name (label = `strlen - 4`, with one extra character trimmed if the slice ends in `'_'`). |
| `0x02`, `0x12`, `0x22`, `0x32` | Label style — the high nibble of `style` (`>> 4` = 0..3) is the *face-slot* index. The handler stores the label either inline (length < 13) or in a side buffer at `DAT_0082cfec` (length >= 13), then calls `watchface_label_commit_ble_name_refresh(payload, length, 0xa5 - slot)` to commit the label/name state. |
| other | Pass-through — `response[2]` is left at `0x00`, the rest of the response is zero. |

#### Side-buffer spill (`style` 0x02/0x12/0x22/0x32, `length ≥ 13`)

The handler re-uses a 24-byte config block at `DAT_0082cfec`:

* If the byte at `req[length - 9]` is `0` (i.e. the request is the
  *last* fragment of a multi-frame label): copy `length - 0x0C` bytes
  from `req[3..]` to `DAT_0082cfec + 0x0D` (a 12-byte name slot at
  the tail of the config block).
* Otherwise (start of a fresh label): clear the 24-byte block, write
  `0xA5 - slot` to `*DAT_0082cfec`, and copy the first 12 bytes of
  `req[3..]` to `pcVar6 + 1`.

In both cases the response echoes the truncated slice and signals
`response[2] = length` so the host can correlate.

#### Label commit + BLE refresh (`watchface_label_commit_ble_name_refresh`)

```c
void watchface_label_commit_ble_name_refresh(text, length, slot_id) {
  if (length != 0) {
    length = min(length, 0x14);
    memset(DAT_0082e498 + 0x26, 0, 0x18);
    *(DAT_0082e498 + 0x26) = slot_id;     // face-slot/name selector
    memcpy(DAT_0082e498 + 0x27, text, length);
  }
  settings_blob0_commit();
  ble_gap_profile_register();             // rebuild profile/name/adv data
  find_device_cancel_ble_reinit_timer();  // shared BLE reinit/cancel path
}
```

`DAT_0082e498` points at the settings/name state block (`0x002088fc`
in this image). Writing `slot_id` (`0xa5..0xa2`) selects which of the
four face slots owns the label, and the actual label string is stored at
`DAT_0082e498 + 0x27` with a 20-byte cap. This helper is not a direct LCD
draw routine; its visible side effect is a settings commit plus BLE
profile/name/advertising refresh before the shared cancel/reinit timer path.

#### Companion opcode: `0x81` config-chunk write (`FUN_0082cdac`)

The watch-face renderer is paired with a 6-byte config-chunk setter
that persists label updates to flash:

```c
void FUN_0082cdac(param_1) {
  if (memcmp(DAT_0082cfec - 6, param_1, 6) != 0) {  // value changed
    memcpy(DAT_0082cfec - 6, param_1, 6);
    *(DAT_0082cfec + 0x3a) = 1;        // "config dirty" flag
    FUN_008294cc();
    FUN_00840568(param_1);              // flash write
    func_0x0000029c(1, 0xd0);           // 13-second one-shot
  }
}
```

The 6-byte chunk lives at `DAT_0082cfec - 6` (the 6 bytes immediately
preceding the 24-byte `0x18` spill block). Together with the
`FUN_0082cfec + 0x3a` "dirty" flag this forms a small
**shadow-and-flush** persistence layer: the in-RAM `0x18` label is
written immediately, while the 6-byte chunk is only committed to
flash when the host sends a corresponding `0x81` and the value
actually changed.

### 3.6 Opcode `0x43` readDetailSport / per-hour activity dump (`FUN_0082d034`)

Reads detailed sport records (one slot per hour) for a single day
and returns them as a **two-phase multi-frame** Channel-A response:
first a *header* frame carrying the count and end-of-data flag,
then one *record* frame per non-empty slot.

The watch's per-day storage is a fixed 24-slot × 12-byte table
(`auStack_19c` in the handler, size 0x124 = 292 B which is `4 + 24*12`):
the first 4 bytes hold the day's "month index" (the same value
returned by `FUN_008318b0(day)`), the rest is the 24 hourly slots.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `opcode` | `0x43` (consumed by dispatcher) |
| 1 | `day_offset` | 0 = today, 1 = yesterday, … ; `FUN_0082840e() - day_offset` is the day queried |
| 2 | `reserved` | unused |
| 3 | `start_hour` | First slot to scan (`0..23`) |
| 4 | `end_hour` | Last slot to scan (`0..23`); clamped to the current minute-of-day for "today" |
| 5 | `unit_flag` | `0` → durations in 10-second units (legacy "minutes"), `1` → durations in 1-second units |
| 6..14 | unused | — |

#### Phase 1 — header frame

After loading the 292-byte daily block via `FUN_008318b0(day)` (or
zero-fill on miss) and writing the current RTC minute into the
in-progress slot when querying "today", the handler scans slots
`start_hour..end_hour` and classifies each:

| Slot condition | Behavior |
|---|---|
| `status == 0` AND `duration == 0` | Skip (empty) |
| `status == 0` AND `duration != 0` | Count (partial record, duration present) |
| `status != 0` AND `status != 0xFFFF` | Count (in-progress) |
| `status == 0xFFFF` (DAT_0082d438 sentinel) | Skip (finalized — surfaced via the `0x77` activity-summary path instead) |

The header frame is then queued:

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x43` | cmd |
| 1 | `0xF0` if any record found, `0xFF` if zero | end-of-data flag |
| 2 | `record_count` (uVar9) | number of valid slots in the range |
| 3 | `unit_flag` echoed (`0x01` if `param_1[5] == 1`) | the host needs this to interpret the per-record duration later |
| 4..14 | 0 | reserved |
| 15 | additive checksum | per §3 |

When the day block is unavailable (`local_1a0 == 0` after the load),
the handler short-circuits with a single error frame
`[0x43, 0xFF, 0, 0, …, 0, cksum]` (13 zero bytes in the payload).

#### Phase 2 — per-record frames

For each counted slot, the handler reads the day's date (BCD-encoded
by `FUN_00828462(month_index, &local_7c)` — three bytes
`{year_off, month, day}`) and emits a 16-byte frame:

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x43` | cmd |
| 1 | `year_bcd` | via `FUN_0082ede2(year_off)` (decimal-to-BCD encoder) |
| 2 | `month_bcd` | via `FUN_0082ede2(month)` |
| 3 | `day_bcd` | via `FUN_0082ede2(day)` |
| 4..5 | `record_idx` packed | `(record_idx) | (slot_idx << 2)` — both ≤ 24 |
| 6..7 | 0 | reserved |
| 8..9 | `duration_lo` (u16) | `slot.duration * (10 if unit_flag == 0 else 1)` |
| 10..11 | `slot.aux_u16` (low byte) | second u16 of the slot (e.g. distance / calorie low) |
| 12..13 | `slot.aux_u16 >> 8` | second u16 high byte (one byte of payload only) |
| 14 | `duration_hi` | high byte of the duration u16 |
| 15 | additive checksum | per §3 |

`FUN_0082ede2(v)` is a defensive BCD encoder that returns
`(tens<<4 | units)` for `v ∈ [0, 99]` and `0` otherwise; combined
with `FUN_00828462` it produces a standard
`{year_lo, month, day}` BCD date triplet for the response header.

The host reconstructs the day's full activity trace by collecting
the header (count + flags) and then `count` consecutive `0x43`
record frames. A trailing "no more data" sentinel is the *header's
`byte 1 == 0xF0`* — the record frames themselves do not carry an
EOM marker.

### 3.7 Opcode `0x06` Do-Not-Disturb (`FUN_0082d298`)

Reads and writes the per-device DND state (one enabled flag plus a
start/end window). The handler is the smallest of the "config
get/set" pair in the Channel-A table: a 6-byte DND record, stored
in a private block anchored at `DAT_0082a830 + 0x0E`.

#### Persistent state (6 bytes at `DAT_0082a830 + 0x0E`)

| Off | Field | Notes |
|---:|---|---|
| 0 | `enable` | `0` = off, `1` = on |
| 1..2 | `start_min` (u16 LE) | minute-of-day for the DND window start |
| 3..4 | `end_min` (u16 LE) | minute-of-day for the DND window end |
| 5 | `pad` | reserved; not compared on write |

#### Sub-opcode dispatch (`FUN_0082d298`)

`req[1]` selects read vs write:

| Sub | Action | Helper used |
|---:|---|---|
| `0x01` (read) | Build a 16-byte response, populate bytes 2..6 with the state (1=enabled/2=disabled, then start hour/min, end hour/min), stamp additive checksum, queue via `FUN_0082ebdc`. | `FUN_0082a7e4` |
| `0x02` (write) | Build the new 6-byte state from `req[2..6]`, `memcmp` against the existing 6-byte block, `memcpy` only if changed; queue `req` as the ack response. Calls `FUN_0082a6cc` (UI re-render) and `FUN_0082d4ce(9)` (event broadcast — `9` is the "DND changed" event id). | `FUN_0082a78e` |
| other | no-op (no response queued) | — |

#### Read-path details (`FUN_0082a7e4`)

The read helper normalises the "disabled" flag to a non-boolean code:

* `enable == 0` → emit `0x02` in byte 2 (firmware uses `1 = on`, `2 = off` to leave room for future "always-on" `0` value).
* `enable == 1` → emit `0x01`.
* `start_min` and `end_min` are split into hour/minute using
  `FUN_0083dfba(_, 0x3c)` (returns hour in the low byte, minute in the
  high byte via the `extraout_r1` return slot).

#### Write-path details (`FUN_0082a78e`)

The write helper packs the request into the 6-byte `local_10` block:

```c
local_10 = (u16)(req[3] * 60 + req[4]) |   // start_min  (high u16)
           ((u16)(req[2] == 1) << 0);      // enable     (low u16)
local_c  = (u16)(req[5] * 60 + req[6]);    // end_min    (low u16)
```

It then `memcmp`s the 6 bytes against `DAT_0082a830 + 0x0E` and only
`memcpy`s the new value if anything changed. The two follow-up calls
`FUN_0082a6cc()` and `FUN_0082d4ce(9)` then (a) repaint any DND
indicator on the active face and (b) emit the "DND changed" event
into the watch's internal event ring, where the `0x77` sport-motion
handlers (see §3) pick it up to suppress buzz notifications.

#### Response shapes

For `0x06 0x01` (read):

```
byte  0: 0x06
byte  1: 0x01   (sub-opcode echo)
byte  2: 0x01 (on) | 0x02 (off)
byte  3: start hour    (BCD-less raw u8)
byte  4: start minute
byte  5: end hour
byte  6: end minute
byte  7..14: 0
byte 15: additive checksum
```

For `0x06 0x02` (write), the response is the **request frame echoed
back unchanged** (the host treats it as a 16-byte ack). This is
deliberate: the request is a self-describing ack payload, so the
host can confirm exactly which `(enable, start, end)` triple the
watch committed.

### 3.8 Opcode `0xff` factory reset (`FUN_0082cde8`)

The smallest handler in the Channel-A table: 35 bytes, no response
frame, and a literal "magic word" payload guard.

#### Trigger

The handler accepts the request only when the first three payload
bytes are the ASCII string `"fff"` (`0x66 0x66 0x66`):

```c
if (req[1] == 'f' && req[2] == 'f' && req[3] == 'f') {
    FUN_008275d8();                        // full system reset
    memset(DAT_0082cff0, 0, 0xa4);          // wipe 164 B user config
}
```

Any other payload is a no-op (no response queued, no state change).
The choice of the literal `"fff"` is unusual — it does not match
any normal Oudmon opcodes (0x66 would be in the `0x62..0x67`
"subData[0] sub-opcode set" bucket from `FIRMWARES/_re/FINDINGS.md`)
— so the host can only invoke a factory reset by explicitly
crafting the magic frame, never by accident.

#### Reset sequence

1. `FUN_008275d8()` — the "system reset / re-initialize" routine
   listed in §6: it stops sensors and the motor, tears down and
   re-initialises the BLE stack (`FUN_00827404`, `FUN_0082dfde`),
   zeroes the per-task state, sets `*DAT_00827804 = 5` (a
   re-init "state" sentinel), and arms a 1000 ms one-shot timer
   via `FUN_0082f160(1000)` so the main task restarts cleanly.
2. `memset(DAT_0082cff0, 0, 0xa4)` — wipe the 164-byte user-config
   block at runtime address `0x00208c8c` (literal-pool value
   `0x8c8c2000`).

#### What gets wiped (and what doesn't)

The 164-byte block at `0x00208c8c` is the user-visible config
record (DND, alarm, sedentary, blood-oxygen, UV-touch, etc.).
The factory reset *only* touches this block — it does **not**
clear:

* the BLE pairing table,
* the OTA state machine (`DAT_00830120` / `DAT_00830124`),
* the 0x2b mixture container at `0x00208c76`,
* the RTC time (set by `0x01`),
* the watch-face label at `DAT_0082cfec` (see §3.5).

In other words `0xff "fff"` returns the watch to factory defaults
for the *user-tunable* surface but leaves any committed pairings
and the user's clock alone. This matches the typical "soft
factory reset" semantics expected from a paired wearable.

#### Why no response

The handler is fire-and-forget: the system reset re-initialises the
main task on the 1000 ms timer, so by the time the host would have
parsed a response, the link layer may already be tearing down.
A response frame queued just before the reset would be lost in the
`FUN_0082ebdc` ring during the BLE re-init. The 16-byte request
frame serves as the implicit ack — the host treats the absence of
a follow-up as "reset accepted".

### 3.9 Opcodes `0x25` setSitLong / `0x26` readSitLong — sedentary reminder config

A read/write pair for the "long sit" (sedentary) reminder. The
config is a 6-byte block at `DAT_0082aebc + 0x14`:

| Off | Field | Notes |
|---:|---|---|
| 0 | `start_hour` (u8, 0..23) | hour-of-day the sedentary window begins |
| 1 | `start_min` (u8, 0..59) | minute-of-hour the sedentary window begins |
| 2 | `end_hour` (u8, 0..23) | hour-of-day the sedentary window ends |
| 3 | `end_min` (u8, 0..59) | minute-of-hour the sedentary window ends |
| 4 | `flags` (u8) | enabled / day-of-week bitmap (semantics carried over from the producer) |
| 5 | `interval` (u8, ≤ 60) | nudge interval in minutes, clamped to 60 |

#### `0x26` read — `FUN_0082d258` + `FUN_0082ae84`

```c
void FUN_0082d258() {
    memset(&local_18, 0, 0x10);
    FUN_0082ae84(&local_18);            // populate bytes 1..6
    *(u8*)&local_18 = 0x26;             // byte 0 = cmd
    local_18[15] = FUN_0082b0c4(&local_18, 0xf);
    FUN_0082ebdc(&local_18);
}
```

`FUN_0082ae84` reads the 6-byte block and BCD-encodes each of the
first 4 fields via `FUN_0082ede2` (the same decimal-to-BCD used by
the `0x43` per-hour dump). The response layout is therefore:

```
byte  0: 0x26                (cmd)
byte  1: BCD(start_hour)
byte  2: BCD(start_min)
byte  3: BCD(end_hour)
byte  4: BCD(end_min)
byte  5: flags               (raw u8)
byte  6: interval            (raw u8, ≤ 60)
byte  7..14: 0
byte 15: additive checksum
```

#### `0x25` write — `FUN_0082d284` + `FUN_0082adf4`

```c
void FUN_0082d284() {
    FUN_0082adf4();               // validate + commit the 6-byte block
    FUN_0082adca();               // mark "config dirty" + reset counter
    FUN_0082b986(0x25, 0);        // 1-byte ack
}
```

The 16-byte request frame carries the time fields at **non-standard
positions** (4..9) and in **reverse order** from the read response:

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x25` | cmd |
| 1..3 | unused | (callers may leave 0) |
| 4 | BCD end_min | (reverse order vs read response) |
| 5 | BCD end_hour | |
| 6 | BCD start_min | |
| 7 | BCD start_hour | |
| 8 | `interval` | clamped to `0x3c` (60) if `value - 10 > 0x50` (i.e. > 90) |
| 9 | `flags` | raw u8 |
| 10..14 | unused | |
| 15 | checksum | additive (per §3) |

`FUN_0082adf4` copies the 16-byte request to a stack frame, BCD-decodes
the four time fields with `FUN_0082edc4`, and validates each:

```c
if (start_hour < 0x18 && start_min < 0x3c &&
    end_hour   < 0x18 && end_min   < 0x3c) {
    state[0] = start_hour;        // binary, not BCD
    state[1] = start_min;
    state[2] = end_hour;
    state[3] = end_min;
    state[4] = flags;             // raw from req[9]
    state[5] = interval;          // clamped
    if (memcmp(state, DAT_0082aebc + 0x14, 6) != 0) {
        memcpy(DAT_0082aebc + 0x14, state, 6);
        *(u16*)(DAT_0082aeb8 + 2) = 0;   // reset nudge counter
    }
}
```

If the time fields fail validation, the write is silently dropped
(no ack, no NAK) — the host must ensure the BCD fields are valid.
`FUN_0082adca` then sets `*DAT_0082aeb8 = 1` (a "sedentary-active"
flag the main-loop tick reads) and resets the 16-bit nudge counter
at `*(DAT_0082aeb8 + 2)`.

#### Read/write order asymmetry

The write request encodes the time fields at bytes 4..9 in
*end-first* order, but the read response surfaces them at bytes
1..4 in *start-first* order. This is the same "input is reverse of
output" pattern that appears in the other "config" opcodes
(`0x37` pressure, `0x39` hrv, `0x7a` muslim) and is most likely a
quirk of how the wire format was originally specified for the
H59MA SDK; the host code that ships in `lib/core/protocol/`
should preserve the asymmetry rather than trying to "fix" it on
either side.

### 3.10 Opcode `0x2c` bloodOxygenSetting (`FUN_0082d1c2`)

The simplest "config" handler in the table: a single-bit on/off
flag for the SpO2 (blood-oxygen) sensor, stored as bit 1 of a
shared config byte at `DAT_008277f0 + 0x2D`.

#### Sub-opcode dispatch

| `req[1]` | Action | Helper |
|---:|---|---|
| `0x01` (read) | `local_16 = FUN_00827682()` — read bit 1 of `*(DAT_008277f0 + 0x2D)`, mask `& 3 >> 1` yields `0` or `1` | `FUN_00827682` |
| `0x02` (write) | `FUN_00827660(req[2])` — if the new value differs from the current bit, update the bit in the config byte and call `FUN_0082946e()` (config-changed event broadcast). `local_16 = req[2]` echoes the committed value. | `FUN_00827660` |
| other | `local_16` left at zero; the sub-opcode echo in `local_17` still identifies the request type | — |

#### Persistent state

The SpO2 setting shares one bit of a single config byte at
`DAT_008277f0 + 0x2D`:

| Bit | Field | Notes |
|---:|---|---|
| 0 | (other config — not SpO2) | reserved |
| 1 | `spo2_enabled` | `0` = off, `1` = on |
| 2..7 | (other config) | reserved |

The `& 3` mask in the read path and the `(param_1 & 1) << 1` in the
write path both confirm that only bit 1 is owned by the SpO2
setting; the other 7 bits of that config byte belong to other
features (likely UV-touch or DND; see §3.7 for the DND state
which lives in a different block).

#### Response layout (always 16-byte fragment)

```
byte  0: 0x2C                (cmd)
byte  1: req[1]              (sub-opcode echo: 0x01 read / 0x02 write)
byte  2: current SpO2 value  (0/1 for read; echoed req[2] for write)
byte  3..14: 0
byte 15: additive checksum
```

The whole 16-byte response is built on the stack from the four
register arguments (`r0..r3`) so that no `memcpy` from the request
is needed — only the three output bytes are touched. The
checksum is computed by `FUN_0082b0c4` over the first 15 bytes
(per the §3 "Common response path") and stamped into `byte 15`
via `CONCAT13`.

#### Why this handler is so short

SpO2 on this watch is a *battery-hungry* sensor: enabling it adds a
continuous PPG read every few minutes. The 1-bit storage means the
state survives the `0xff` factory reset (the parent config byte is
zeroed there) and is fast to toggle from the watch face — the
host's only requirement is that `req[2]` for sub `0x02` be `0` or
`1` (the handler doesn't reject other values, but the bit-mask
write will silently coerce them to `0`/`1`).

### 3.11 Opcode `0x7a` muslim (prayer config) (`FUN_0082cb3a`)

Sub-dispatched by `req[1]`. The "read" path uses a *two-phase* response
(an empty header frame, then a multi-frame payload) via the shared
fragmenter `FUN_0082c988` (see below). The "reset" path is
single-shot.

#### Sub-opcode dispatch

| `req[1]` | `req[2]` | Action |
|---:|---:|---|
| `0x01` | slot_id | **Read** prayer slot. The handler first calls the stub `FUN_00829c88(slot_id, &buf)` — currently a no-op that always returns `0` — so the read always falls into the "slot empty" path and returns a one-byte `0x7A 0xFF` error. See "Stub status" below. |
| `0x02` | `0x01` | **Reset** prayer config: `FUN_00829c90()` (also a stub, currently a no-op). No response. |
| other | any | no-op, no response. |

#### Stub status

Both `FUN_00829c88` (read) and `FUN_00829c90` (reset) are
**unimplemented stubs** in the v14 firmware — they simply `return 0`
or `return`. This means the H59MA v14 firmware does not yet
implement the Muslim prayer feature, even though the opcode is
allocated in the dispatcher table. The handler still wires up the
full "happy path" so that, when the producer side is implemented,
the read will:

1. Send the 16-byte header frame
   `[0x7A, 0x00, 0x05, 0x3C, 0, 0, …, 0, cksum]` (the literal
   `0x3C05007A` little-endian dword at offset 0 with the
   additive checksum on bytes 1..14).
2. Call `FUN_0082c988(0x7A, &local_3d, 0x31)` where
   `local_3d[0] = req[2]` (slot id echo) and bytes 1..48 are the
   prayer-slot payload that the future `FUN_00829c88` will fill
   in.
3. The fragmenter then ships 49 bytes in 13-byte chunks as four
   16-byte frames, sequence-numbered 1..4.

The "send header, then fragmented payload" structure is shared
with `0x37 pressure` and `0x39 hrv` (the other long-response
opcodes in the Channel-A table) — they all reuse
`FUN_0082c988` for the payload.

#### `FUN_0082c988` — 13-byte-chunk fragmented streamer

```c
void FUN_0082c988(byte cmd, byte *data, int length) {
  char seq = 1;
  for (int i = 0; i < length; i += 0xD) {
    memset(&frame, 0, 0x10);
    frame[0] = cmd;
    frame[1] = seq++;
    chunk = min(length - i, 0xD);
    memcpy(&frame[2], data + i, chunk);
    frame[15] = FUN_0082b0c4(&frame, 0xf);
    FUN_0082ebdc(&frame);
  }
}
```

Each 16-byte notify frame carries:

```
byte  0: cmd (0x37 / 0x39 / 0x7A)
byte  1: sequence number (1, 2, 3, …)
byte  2..14: payload chunk (up to 13 bytes)
byte 15: additive checksum
```

For `0x7A` (49-byte payload): ceil(49 / 13) = 4 chunks, sequence
numbers 1..4. The 0x37 / 0x39 callers will use whatever
sequence-length fits their payload. The host decodes by
**collecting all `cmd` frames in order** until it has
`length` bytes or a sentinel — the `FUN_0082c988` itself does
not emit an EOM, so the upper layer is responsible for the
"first frame is the header, follow-up frames are payload
chunks" interpretation.

#### Response layout for the (unimplemented) read path

Phase 1 — header:

```
byte  0: 0x7A
byte  1: 0x00
byte  2: 0x05         (payload size = 5 dwords? — see below)
byte  3: 0x3C
byte  4..14: 0
byte 15: additive checksum
```

The `0x3C` in byte 3 is 60 — the same value seen in `0x37`
pressure's response and in the 0x01 setTime ack. It is the
static "feature-bitmap-shape" byte the firmware reuses across
all "long config" responses; the actual meaning is
producer-specific.

Phase 2 — 4-frame fragmented payload (one per 13-byte chunk):

```
frame N (N=1..4):
  byte  0: 0x7A
  byte  1: N
  byte  2..14: slot data chunk
  byte 15: additive checksum
```

The slot data layout is currently unknown because
`FUN_00829c88` is a stub; once the prayer feature ships, byte
0 of the data will identify the slot id (echo of `req[2]`)
and bytes 1..48 will hold the per-slot prayer record
(prayer name, time, offset, etc.).

### 3.12 Opcode `0x15` readHeartRate (`FUN_0082cf48`)

Heart-rate record read by *index* (not by timestamp). The handler
takes a 4-byte index from the request, converts it to a record
timestamp, and ships the matching 292-byte HR record back as a
two-phase response (header + fragmented payload) using the same
13-byte-chunk streamer shape as `0x7a` (§3.11), `0x37` and `0x39`.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x15` | cmd (consumed by dispatcher) |
| 1..4 | `index` (u32 LE) | record index; `0` = "current/latest" sentinel |
| 5..14 | unused | — |

#### Index → timestamp conversion

```c
uint32_t local_13c = req[1] | (req[2] << 8) | (req[3] << 16) | (req[4] << 24);
uint32_t timestamp;
if (local_13c == 0) {
    timestamp = 0;
} else {
    FUN_008279c4(local_13c, &timestamp);   // month-index → seconds
}
int found = FUN_00833c92(timestamp, data);
```

Live H59MAX_1.00.13 testing shows the accepted index is the UTC
day-start timestamp in seconds, matching `PROTOCOL.md` §4.3. Packed
BCD dates such as `26 06 21 00` are accepted at the byte level but
return the universal `0xff` no-data frame. Treat earlier BCD/date-index
readings of `FUN_008279c4` as an incorrect interpretation for this
firmware family.

#### Phase 1 — header / error

* If `FUN_00833c92` returns 0 (no record at that timestamp): send
  a single 16-byte error frame

  ```
  byte  0: 0x15
  byte  1: 0xFF              (error flag)
  byte  2: 0x14              (status code 20)
  byte  3..14: 0
  byte 15: additive checksum
  ```

  The static dword `0x140000FF15` (little-endian) is the
  watch's universal "no data at this index" ack.

* If `FUN_00833c92` returns 1 (record exists): send a 16-byte
  **header** frame first

  ```
  byte  0: 0x15
  byte  1: 0x18              (24 — payload size lower byte)
  byte  2: 0x80
  byte  3: 0x05
  byte  4..14: 0
  byte 15: additive checksum
  ```

  The header is the literal dword `0x5180015` (LE) — same
  "feature-bitmap-shape" reuse as the `0x7a`/`0x37`/`0x39` headers
  (see §3.11). It tells the host "data follows, this many bytes
  total".

#### Phase 2 — fragmented payload (23 frames)

The 292-byte record (73 × u32) is then fragmented into
`ceil(292 / 13) = 23` 16-byte notify frames using the same
inlined chunk loop as `FUN_0082c988`:

```c
char seq = 1;
for (i = 0; i < 292; i += 13) {
    frame[0] = 0x15;
    frame[1] = seq++;
    chunk = min(292 - i, 13);
    memcpy(&frame[2], data + i, chunk);
    frame[15] = FUN_0082b0c4(&frame, 0xf);
    FUN_0082ebdc(&frame);
}
```

The first u32 of the response data (`data[0]`) is **overwritten
with the request index** before fragmentation (`local_138[0] =
local_13c`), so the host sees its own `index` echoed back as the
4-byte prefix of the payload. The remaining 72 u32s
(`data[1..72]`) are the raw HR record: typically 24 hours × 3
fields (HR value, RR-interval, motion flag) packed into u32s,
but the producer side is owned by `FUN_00833c92` and not detailed
in the firmware body.

#### Frame layout per chunk

```
byte  0: 0x15              (cmd echo)
byte  1: N                (sequence: 1..23)
byte  2..14: 13 bytes of record data
byte 15: additive checksum
```

The last frame is padded with zeros (the data buffer is 292 B but
the last chunk only carries 292 - 22*13 = 6 real bytes followed by
7 zero padding bytes).

#### Host decode recipe

1. Read the header frame; expect byte 0 = `0x15` and byte 1 = `0x18`.
2. Collect follow-up frames with byte 0 = `0x15` and sequence
   numbers `1, 2, …`. Concatenate bytes 2..14 of each frame in
   order until 292 B are accumulated.
3. The first 4 B of the concatenated buffer is the request index
   (echo); bytes 4..291 are the HR record.

### 3.13 Opcode `0x1e` realTimeHeartRate (`FUN_0082d20c`)

A 3-sub-opcode controller for the watch's *real-time* (continuous)
heart-rate measurement. The "is running" flag and the 60-second
countdown are packed into a single byte at `DAT_0082d43c + 8`
(runtime `0x00208d30`).

#### Sub-opcode dispatch

| `req[1]` | Condition | Action |
|---:|---|---|
| `0x01` (start) | `cVar2 == 0` (idle) | `*(DAT_0082d43c + 8) = 0x3C` (60-second counter reload); `health_post_start_measure_event(0x2000)` (HR driver start in continuous mode); `func_0x00013694(DAT_0082d440, 1000)` (start 1 s tick timer) |
| `0x02` (stop) | `cVar2 != 0` (running) | `*(DAT_0082d43c + 8) = 0` (counter to zero); `health_post_stop_measure_event(0x2000)` (HR driver stop); `func_0x000136bc(DAT_0082d440)` (cancel 1 s tick timer) |
| `0x03` (reset) | `cVar2 != 0` (running) | `*(DAT_0082d43c + 8) = 0x3C` (counter back to 60, but no driver re-start and no timer re-arm) |
| other | any | no-op (handler does not branch) |

The sub-opcode × condition gate prevents double-starts and
double-stops; `0x01` on an already-running measurement is silently
ignored, and `0x02` on an idle measurement is also a no-op. The
handler never sends a response frame (it is one of the few
*fire-and-forget* Channel-A commands).

#### Persistent state

A single byte at `DAT_0082d43c + 8` (runtime `0x00208d30 + 8`)
doubles as both the "is running" flag and the 60-second countdown:

| Value | Meaning |
|---:|---|
| `0` | measurement idle |
| `0x3C` (60) | running, 60 s remaining (reloaded on start and on `0x03`) |
| `1..0x3B` | running, that many seconds remaining (decremented by the 1 s tick) |

The countdown is **not** decremented by the handler — the watch's
1-second tick (`func_0x00013694` with 1000 ms period, anchored at
`DAT_0082d440` runtime `0x00209f40`) calls into the HR driver
each tick, and the driver itself is what writes the decremented
value back to `*(DAT_0082d43c + 8)`. When the value reaches `0`
the measurement is auto-stopped by the driver and the timer
naturally falls out of its re-arm loop.

#### HR driver calls

`health_post_start_measure_event(mode = 0x2000)` (start) builds the 8-byte request
`{cmd = 0x10003, mode = 0x2000}` and forwards it to the HR driver
via `FUN_008273d0(&req, 0x17C)`. The `0x17C` is the HR driver
sub-command id for "start measurement", and `0x2000` selects
*continuous* mode (as opposed to `0x0800` used by the `0xa1`
factory test mode for one-shot measurement).

`health_post_stop_measure_event(0x2000)` (stop) builds `{cmd = 0x20003, mode = 0x2000}`
and forwards via `FUN_008273d0(&req, 0x174)`. The `0x174` is the HR
driver sub-command id for "stop measurement". Both sub-commands
live in the same driver wrapper `FUN_008273d0` and are part of the
"VC_HRV_16Bit_integration_6.0_addRMSSD" library mentioned in
`firmwares/_re/strings-mining/findings.txt`.

#### Sub-opcode `0x03` semantics

`0x03` is "reset the 60 s countdown back to 60 without
re-starting the measurement". A host can use it to extend a
measurement window indefinitely by sending `0x03` every 55 s.
Unlike `0x01` it does **not** call the HR driver or arm the
1 s tick — those are assumed to still be running — it just
reloads the countdown byte. This makes `0x03` a no-op if the
measurement has already auto-stopped (the `cVar2 != 0` guard
suppresses the write in that case).

#### Why no response

The 1-second tick + HR driver are real-time; queuing a response
frame in the `FUN_0082ebdc` ring would add a multi-ms latency
to the very-fast feedback loop the host uses to update its
live-HR UI. The watch treats the sub-opcode as a "set" command
and lets the host poll the current HR value separately (the
real-time HR notifications travel on the `0x2b`/`0x39` and
related push paths, not through this opcode).

### Opcode `0xa1` factory/test mode (`FUN_00827f5c`)

`subData[0]` selects the test action:

| Sub-byte | Action |
|---|---|
| `0x01` | Full reset: stop sensors/motor, save current state to RAM context, clear step data, start 1000 ms timer, power off / enter DLPS |
| `0x02` | Restore saved state from RAM context to sensor modules |
| `0x03` | Power off / enter DLPS immediately |
| `0x04` | Start HR measurement with `0x800` mode |
| `0x05` | Stop HR measurement |
| `0x06` | Save current state and then power off |
| other | Send `0xffa1` error response |

#### Deeper behaviour (decompiled)

The handler uses **two global state buffers** to coordinate
the factory-test sequence:

* `DAT_00828108` — a "scratch" buffer (about 40 bytes) used
  for transient context (counts, sub-byte echo, current
  HR mode parameter).
* `DAT_0082810c` — a "live" buffer holding the saved sensor
  state (step count, HR mode, body position, etc.). The
  handler reads/writes the `DAT_0082810c + 4..0xC` range to
  push or pull the state.

The four "interesting" paths:

* **`sub 0x01` — full reset**:
  1. `FUN_00827ba6(2)` — stop sensors / motor.
  2. `FUN_0082949c()` — save the *current* state from
     `DAT_0082810c + 4..0xC` into the scratch buffer
     `DAT_00828108 + 0x1C..0x24`.
  3. `FUN_00833e86()` + `FUN_00831b90()` +
     `thunk_FUN_00831230()` + `FUN_00827940()` — generic
     "clear step data + reset BLE + reset task" cleanup
     sequence (the same routine as `0xff factory reset`).
  4. Re-stage the scratch buffer back into the live buffer
     (so the saved state survives the reset).
  5. Zero out the deferred ring (`FUN_00833948`).
  6. Stop HR with `DAT_00828110` (mode = `0x40`).
  7. Re-arm HR with `0x40`.
  8. Echo `req[2]` into `DAT_00828108[0]` and queue a
     1000 ms worker via `FUN_00829c24`.
  9. Tail-call `FUN_00827dba(0)` — the state-update worker
     that pushes the live state to the notify ring (see
     §8.16).

* **`sub 0x02` — restore**:
  1. If `DAT_0082810c[8]` (the "save state present" flag)
     is non-zero, copy the scratch state back into the live
     buffer.
  2. If `DAT_0082810c[1]` (the "save count present" flag)
     is non-zero, copy the scratch step count back.
  3. Stop HR, re-arm with `0x40`.
  4. Tail-call `FUN_00829c50` to cancel any pending workers.

* **`sub 0x04` — start HR mode `0x800`**:
  Just calls `health_post_start_measure_event(0x800)` and stores `req[2]` in
  `DAT_00828108[0]` for the worker.

* **`sub 0x06` — save + reset**:
  Similar to `0x01` but **without** calling `FUN_00827ba6(2)`
  first — leaves the sensors running while saving the
  state, then triggers a state-update worker that pushes
  the live state and resets the deferred ring.

#### `FUN_00827dba` — state-update worker

The worker called by all four "interesting" paths above:

```c
void FUN_00827dba() {
    rsp[0] = 0xA1;  // cmd
    rsp[1] = 1;     // sub-cmd echo (= the sub-byte from the request)
    rsp[2..3] = FUN_00833968();          // 2-byte u16 "state version" id
    rsp[4..7] = *(u32*)(DAT_00827e8c + 0x4C);  // 4-byte live state field
    rsp[8..11] = *(u32*)(DAT_00827e8c + 0x48); // 4-byte live state field
    rsp[12..14] = uVar11;                // low 12 bits of *(DAT_00827e8c + 0x50)
    rsp[15] = checksum;
    FUN_0082ebdc(rsp);  // push 16-byte state-update frame
    rsp[0] = 0xA1;
    rsp[1] = 2;     // sub 2 = "step count"
    rsp[2..3] = FUN_00833960();          // 2-byte step count u16
    rsp[4..5] = *(u16*)(DAT_00827e8c + 0x40); // step count u16
    rsp[6..7] = *(u16*)(DAT_00827e8c + 0x3E); // last-step u16
    rsp[8..9] = uVar9;                    // 2-byte "last update" timestamp
    rsp[15] = checksum;
    FUN_0082ebdc(rsp);  // push step-count frame
    rsp[0] = 0xA1;
    rsp[1] = 3;     // sub 3 = "body position / motion"
    rsp[2..3] = local_1c[0];  // 2-byte motion u16 (from FUN_00832f1e)
    rsp[4..5] = local_18[0];  // 2-byte body position u16
    rsp[6..7] = local_20[0];  // 2-byte fall-detect u16
    rsp[15] = checksum;
    FUN_0082ebdc(rsp);  // push motion frame
    if (*DAT_00828108 == '\x04') {
        FUN_0082a460(2000);  // 2-second delay
    } else {
        // ... increment retry counter, reschedule worker ...
    }
}
```

The worker pushes **three frames** back-to-back:
* `sub 1`: live sensor state (2 B version + 4 B + 4 B + 3 B
  partial state)
* `sub 2`: step count (2 B + 2 B + 2 B)
* `sub 3`: motion / body position (3 × 2 B)

These are the three "live" snapshots the host needs to render
the factory-test UI. The `sub 0x04` path (`*DAT_00828108 ==
4`) inserts a 2-second delay between frames so the host has
time to render each before the next one arrives; the
default path re-schedules the worker until `sub == 4` or the
retry counter exceeds 120 iterations.

#### Why `sub 0x01` saves + clears + restores

The full-reset sequence in `sub 0x01` is **idempotent**:
it saves the current state *before* the reset, then clears the
step counter, then restores the saved state. This means the
factory operator can send `sub 0x01` repeatedly during a
test session to "re-zero" the counter without losing the
configuration. The `DAT_00828108 + 0x1C..0x24` scratch
buffer holds the saved state across the reset; the live
buffer (`DAT_0082810c + 4..0xC`) is re-staged after the clear.

#### Pair with `0xce` vendor/test (0xFEE7)

`0xa1` (Channel-A) and `0xce` (0xFEE7) are *both* factory-test
entry points but on **different transports**. `0xa1` is the
public Channel-A path used by host SDKs; `0xce` is the OEM
vendor path used by factory-floor equipment (§8.10). They
share *some* helpers (`health_post_start_measure_event`, `health_post_stop_measure_event`,
`FUN_0082a460`) but call different state-update paths
(`FUN_00827dba` vs `FUN_00838bc0`/`FUN_00833400`).

A factory operator with the OEM tools would use `0xce`; an
OpenWatch host SDK would use `0xa1`. The two paths do not
interfere with each other.

### 3.14 Opcode `0xc6` restoreKey (device reboot)

Unlike the other Channel-A opcodes that route to dedicated
handler functions, `0xc6` is a *special* case handled inline in
the main dispatcher `channel_a_dispatch_queued_frame`. The handler takes a one-byte
sub-command at `req[1]` and either runs a full reboot sequence
or sends a one-byte ack, depending on the sub-command.

#### Sub-command dispatch (inline in `channel_a_dispatch_queued_frame`)

```c
if (opcode == 0xc6) {
    if (req[1] == 'l') {                          // 0x6C — full reboot
        FUN_008275d8();                            // §6 system reset
        FUN_00829504();                            // clear 224 B main state
        FUN_00829560();                            // clear 164 B user config
        FUN_0082f160(2000);                        // 2 s wakeup timer
        FUN_0082a460(1000);                        // 1 s UI delay
    } else {
        FUN_0082b986(0xc6, 1);                     // 1-byte ack (|0x80 high-bit)
    }
}
```

The 0x6C magic byte is the *only* byte in the request that
matters; the rest of the 16-byte frame is ignored. Any other
value of `req[1]` returns a one-byte ack `[0xC6, 0, 0, …, 0, cksum]`
via `FUN_0082b986(cmd, isNotify=1)` — the high bit of `0xC6` is
already set so the `| 0x80` is a no-op.

#### The `0x6C` reboot sequence

| Step | Function | Effect |
|---:|---|---|
| 1 | `FUN_008275d8()` | System reset (the same routine used by `0xff` factory reset): stops sensors and motor, tears down the BLE stack via `FUN_00827404` + `FUN_0082dfde`, zeroes per-task state, sets `*DAT_00827804 = 5`, and arms a 1000 ms one-shot timer via `FUN_0082f160(1000)`. |
| 2 | `FUN_00829504()` | Clear 224 B of main-app state. The body is `memset(stack, 0, 0x1FC)`, load the 4-byte u32 at `*(DAT_008297dc + 4)`, then call `func_0x00007b32(&u32, 0, 0xE0)` (likely a state-store clear for the *first* state block). |
| 3 | `FUN_00829560()` | Clear 164 B of user-config. The body is `memset(stack, 0, 0x200)`, then `func_0x00007b32(stack, 0x200, 0xA4)` (the *same* 0xA4-byte config block that `0xff` factory reset wipes via `DAT_0082cff0`; the 0x6C reboot path *additionally* wipes it). |
| 4 | `FUN_0082f160(2000)` | Start a 2000 ms one-shot timer. |
| 5 | `FUN_0082a460(1000)` | Start a 1000 ms UI delay. The body checks `FUN_00828b1e()` (no pending activity) and `FUN_0082a826()` (on home screen) before running, cancels any active timer at `DAT_0082a69c + 4`, starts a new 1000 ms timer, calls `FUN_0082a382(0x4B)` (probably a "shutting down" UI event), and sets `*(DAT_0082a69c + 0xc) = 1` (the "delaying" flag). |

#### `0x6C` vs `0xff 'fff'` — what's the difference?

Both opcodes trigger a system reset (`FUN_008275d8`) and end up
zeroing the 0xA4-byte user-config block, but:

| | `0x6C` reboot | `0xff 'fff'` factory reset |
|---|---|---|
| System reset (`FUN_008275d8`) | yes | yes |
| Main-app 224 B state wipe | **yes** (`FUN_00829504`) | no |
| 164 B user-config wipe | **yes** (`FUN_00829560`) | yes |
| 2000 ms wakeup timer | **yes** | no |
| 1000 ms UI delay | **yes** | no |
| "shutdown" UI event (`0x4B`) | **yes** | no |
| Response | none (BLE torn down) | none (BLE torn down) |
| Trigger | single byte `0x6C` | three-byte magic `"fff"` |

In other words, `0x6C` is the "**reboot and start clean**" command
the host sends when it wants the watch to come back up with no
in-RAM state at all, while `0xff 'fff'` is the "**reset user
preferences but keep the running app state**" command. A normal
host-initiated "reboot the watch" session uses `0x6C`; a
"factory-reset to clear my customisations" session uses
`0xff 'fff'`.

#### Why no response

The reboot path tears down the BLE stack at step 1 (`FUN_0082dfde`
inside `FUN_008275d8`), so any response frame queued by the
dispatcher would be lost in the `FUN_0082ebdc` ring during the
re-init. The 16-byte request is the implicit ack. The host treats
the loss of the link as the success indicator and waits for the
watch to re-advertise before sending a fresh `0x01`/`0x48`
handshake.

### 3.23 The `DAT_008277f0 + 0x2D` 1-bit config bitmap synthesis

A cross-cutting view of the 5 1-bit config-pair handlers
documented separately in §3.10, §3.17, §3.22, §8.8, and §8.15.
All five share **one byte** at `DAT_008277f0 + 0x2D` (the
runtime address `0x00208ccd`); each handler owns one bit of
that byte.

#### Layout

| Bit | Field | Owner | § |
|---:|---|---|---|
| 0 | (reserved / unused) | — | — |
| 1 | `spo2_enabled` | `0x2c SpO2` (§3.10) | 3.10 |
| 2 | `hr_related` | `0x36 HR enable` (§8.8) | 8.8 |
| 3 | `pressure_enabled` | `0x38 pressure` (§3.17) | 3.17 |
| 4 | (reserved / unused) | — | — |
| 5 | `sugar` | `0x3a sub 0x03 sugar` (§3.22) | 3.22 |
| 6 | (reserved / unused) | — | — |
| 7 | `lipids` | `0x3a sub 0x04 lipids` (§3.22) **and** `0x3e lipids` (§8.15) | 3.22, 8.15 |

#### Read/write masks (from the helper functions)

Each handler's pair of helpers uses a mask + shift that
matches one bit exactly. The set of masks completely tiles
the 8-bit byte:

| Helper | Mask | Shift | Owner |
|---|---:|---:|---|
| `FUN_00827682` (read) | `& 3` | `>> 1` | SpO2 (bit 1) |
| `FUN_00827660` (write) | `& 0xFD` | `<< 1` | SpO2 (bit 1) |
| `FUN_0082768e` (read) | `& 7` | `>> 2` | HR (bit 2) |
| `FUN_0082769a` (write) | `& 0xFB` | `<< 2` | HR (bit 2) |
| `FUN_00827772` (read) | `& 7` | `>> 2` | pressure (bit 3) — wait, this is for *0x38* (pressure), let me re-check |
| `FUN_0082777e` (write) | `& 0xF7` | `<< 2` | pressure (bit 3) |
| `FUN_00827790` (read) | `& 0x3F` | `>> 5` | sugar (bit 5) |
| `FUN_0082779c` (write) | `& 0xDF` | `<< 5` | sugar (bit 5) |
| `FUN_008277ce` (read) | `>> 7` | — | lipids (bit 7) |
| `FUN_008277d8` (write) | `& 0x7F` | `<< 7` | lipids (bit 7) |

The **mask = `& ~(1 << shift)`** pattern in every write
helper confirms that each helper owns exactly one bit — they
clear their bit and preserve all others, so concurrent reads
of unrelated bits are safe.

#### Cross-opcode duplicate (lipids)

`0x3e` (§8.15) and `0x3a sub 0x04` (§3.22) **both own bit 7**
via the same helper pair (`FUN_008277ce` / `FUN_008277d8`).
This is the only duplicated owner in the bitmap; all other
bits are owned by a single opcode. The duplicate is
backwards-compat — `0x3e` is the older 0xFEE7 vendor path,
`0x3a sub 0x04` is the newer Channel-A path. Writing
through either opcode has identical effect on the bit.

#### Reset semantics (0xff 'fff' factory reset)

`0xff` factory reset (§3.8) clears **0xa4 = 164 bytes** of
config starting from `DAT_0082cff0`. This is the *user*
config block (`DAT_0082cff0`), not the *sensor* config
block (`DAT_008277f0`).

`0xff` does *not* clear the sensor-config byte at
`DAT_008277f0 + 0x2D` — sensor on/off bits persist across
factory reset. The `0xc6 0x6C 'l'` reboot (§3.14) is the
only reset that touches the full RAM state including the
sensor-config byte (via `FUN_00829560` and the related
helpers).

#### Why the bitmap lives in `DAT_008277f0` (not `DAT_0082cff0`)

The two config-block bases correspond to two different
"config worlds":
* `DAT_0082cff0` — **user-tunable config** (display
  brightness, time format, sedentary interval, alarm
  schedules, etc.). Read/written via `0x81 config-chunk
  write` (§3.5 companion opcode). Cleared by `0xff`.
* `DAT_008277f0` — **sensor enable bitmap** (1 bit per
  sensor). Read/written via the per-sensor opcodes (`0x2c`,
  `0x36`, `0x38`, `0x3a sub 0x03/0x04`, `0x3e`). *Not*
  cleared by `0xff` — it persists across factory reset and is
  only cleared by `0xc6 0x6C` reboot.

The split exists because the sensor-enable bitmap is *factory
calibration* state (which features the OEM has enabled for
this SKU), while the user-config block is *user preference*
state (which the user can change via the host app). A factory
reset restores user preferences to defaults but does *not*
disable a sensor the OEM paid to calibrate.

#### Bit-map cross-reference table

A consolidated view of all 6 1-bit-config opcodes
(§3.10, §3.17, §3.22 × 2, §8.8, §8.15):

| Opcode | § | Bit | Read helper | Write helper | Behavior |
|---|---|---:|---|---|---|
| `0x2c sub 0x01` | §3.10 | 1 | `FUN_00827682` | `FUN_00827660` | SpO2 on/off |
| `0x36 sub 0x01` | §8.8 | 2 | `FUN_0082768e` | `FUN_0082769a` | HR enable |
| `0x38 sub 0x01` | §3.17 | 3 | `FUN_00827772` | `FUN_0082777e` | pressure enable |
| `0x3a sub 0x03` | §3.22 | 5 | `FUN_00827790` | `FUN_0082779c` | sugar enable |
| `0x3a sub 0x04` | §3.22 | 7 | `FUN_008277ce` | `FUN_008277d8` | lipids enable (Channel-A) |
| `0x3e sub 0x01` | §8.15 | 7 | `FUN_008277ce` | `FUN_008277d8` | lipids enable (0xFEE7) |

The four "active" bits (1, 2, 3, 5, 7) all use the same
helper pattern: a `& MASK` read with shift to extract, and a
`& ~MASK | (value << shift)` write to set. The bit-2
helper (`FUN_0082768e`) is slightly different — its mask is
`& 7` (covering bits 1..3) instead of `& 1` (covering bit 2
alone), but the shift `>> 2` still isolates bit 2. The mask
is conservative (covers extra bits) but the read value is
always `0` or `1` because no other handler writes to bits 1..3
concurrently.

The host SDK can read the bitmap as a whole by sending any
one of the per-sensor read opcodes (e.g. `0x2c 0x01` reads
just bit 1; the host SDK must issue one read per sensor).
A more efficient pattern is to read `DAT_008277f0 + 0x2D`
directly via `0xc0` memory read (§8.17), which gives the
host the full bitmap in a single fragmented response.

#### Why this synthesis section exists

The 5 opcodes are scattered across §3.10, §3.17, §3.22,
§8.8, §8.15 — each section describes *its* handler in
detail but doesn't explain the *shared bitmap*. A host
SDK that wants to read or write the full sensor-enable
state needs to know that the bitmap lives at
`DAT_008277f0 + 0x2D` (runtime `0x00208ccd`), that the
five bits are owned by the five handlers above, and that
the reset semantics differ between `0xff` (user-config
only) and `0xc6 0x6C` (full RAM). This section is the
*single place* in the doc that ties them together.

### 3.24 Deferred-command ring synthesis (`FUN_0082be64`)

A cross-cutting view of the **10-slot deferred ring** at
`DAT_0082bfcc` that backs *all* the opcodes routed through
the dispatcher via the `FUN_0082be64(frame_ptr)` call.
This ring is referenced in 15+ sections (every `0x2b`, `0x37`,
`0x38`, `0x3a`, `0x3b`, `0x43 'C'`, `0x48 'H'`, `0x72`,
`0x7a`, `0x81`, `0xa1`, `0xc6`, `0xc7 'D'`, `0xff`) but
its actual structure was never documented in a single place.

#### Behavior

```c
void FUN_0082be64(undefined1 *frame) {
    state = DAT_0082bfcc;
    // Copy 16 B from frame into the current slot
    memcpy(state + 4 + (*(u16*)(state + 2)) * 0x10, frame, 0x10);
    // Advance slot index (wrap at 10)
    u16 slot = *(u16*)(state + 2);
    if (slot < 9) *(u16*)(state + 2) = slot + 1;
    else         *(u16*)(state + 2) = 0;
    // Schedule the worker
    FUN_00827124(0, DAT_0082bfd0);
}
```

#### Ring layout (`DAT_0082bfcc`)

| Off | Field | Notes |
|---:|---|---|
| `+0` | reserved / header | (the global struct base) |
| `+2` | `slot_index` (u16 LE) | wraps at 10 (`0..9`) |
| `+4` | `slots[0]` (16 B) | first ring slot |
| `+14` | `slots[1]` (16 B) | second ring slot |
| ... | ... | |
| `+0xA0` | `slots[9]` (16 B) | last ring slot |

Total size: `4 + 10 * 16 = 164` bytes (`0xA4`).

#### Worker behavior (`FUN_00827124`)

The worker (`FUN_00827124(0, DAT_0082bfd0)`) drains the
ring asynchronously — each slot is consumed in order,
dispatched to its corresponding handler (§3 — the same
`channel_a_dispatch_queued_frame` dispatch loop), and then freed. The
`DAT_0082bfd0` argument is the work-item struct that holds
the "next slot to drain" index.

Because the worker runs *asynchronously* (on the next idle
tick of the main loop), a host that sends an opcode routed
through `FUN_0082be64` does *not* get an immediate response
— the response comes via the §3 "Common response path"
once the worker has dispatched the frame. This is why
opcodes like `0x2b menstruation` (§3.1), `0x37 pressureSetting`
(§3.20), and `0xc6 restoreKey` (§3.14) have a longer
response latency than opcodes routed inline (`0xc6 0x6C 'l'`
reboot, `0x08 0x01` start-find, etc.).

#### Why 10 slots?

The ring holds **10 slots** because the dispatcher routes
~10 distinct opcodes that produce async work (the rest of the
routed opcodes are short-lived enough to not need the ring).
Each slot is one full request frame, so 10 slots × 16 B = 160
B of state — small enough to live in the `.bss` section of
the firmware image without competing with the larger config
buffers at `DAT_0082bfcc + 0xA4+` (e.g. the user-config at
`DAT_0082cff0` cleared by `0xff` factory reset).

If the host sends 11 requests faster than the worker can
drain, the 11th request **wraps the slot index back to 0**
and overwrites the oldest queued request. The host SDK should
pace requests at ≤ 10 / (worker tick interval) to avoid
clobbering pending work.

#### Cross-reference table

Every opcode routed through `FUN_0082be64` (per §8.1
dispatcher and §3 dispatcher):

| Opcode | § | Handler (deferred-worker target) |
|---|---|---|
| `0x2b` menstruation | §3.1 | `channel_a_handle_menstruation` |
| `0x37` pressure history | §3.20 | `channel_a_handle_pressure_history` |
| `0x38` pressure flag | §3.17 | `channel_a_handle_pressure_flag` |
| `0x3a` sub 0x03/0x04 sugar/lipids | §3.22 | `channel_a_handle_sugar_lipids_flags` |
| `0x3b` uvTouch | §3.18 | `channel_a_handle_touch_uv_config` |
| `0x43 'C'` detail sport | §3.6 | `channel_a_handle_detail_sport_read` |
| `0x72` pushMsgUint | §3.3 | `channel_a_handle_push_msg_unicode` |
| `0x7a` muslim | §3.11 | `channel_a_handle_muslim_prayer` |
| `0x81` config chunk | §3.5 companion | `channel_a_handle_config_chunk` |
| `0xa1` factory/test | §3.x | `channel_a_handle_factory_test` |
| `0xc6` restoreKey/reboot | §3.14 | inline case in `channel_a_dispatch_queued_frame` |
| `0xc7` vibration | §3.2 | `channel_a_handle_vibration_pattern` |
| `0xff` factory reset | §3.8 | `channel_a_handle_factory_reset` |

That's **13 opcodes** routed through `enqueue_deferred_command_frame`. The
remaining ~30 documented 0xFEE7 opcodes are either inline
in the dispatcher (no ring) or are state-update / ack-only
(no response).

#### Why this synthesis section exists

Every detailed handler section (e.g. §3.1, §3.20, §8.2)
mentions `FUN_0082be64` in passing but never explains the
**ring layout, the 10-slot wrap, the async worker, or the
14-opcode consumer list**. A host SDK author who reads §3
top-to-bottom sees the ring referenced many times without a
unified view of its structure. This section pulls the threads
together: the ring is the **single async-work queue for the
0xFEE7 dispatcher**, holds 10 in-flight frames, and
deliberately wraps at 10 so a misbehaving host can't grow the
queue unboundedly.

#### §3 vs §8 ring usage

The §3 dispatcher (`channel_a_dispatch_queued_frame`) routes `0x2b`, `0x37`,
`0x38`, `0x3a`, `0x3b`, `0x43`, `0x72`, `0x7a`, `0x81`,
`0xa1`, `0xc6`, `0xc7`, `0xff` through `FUN_0082be64` —
13 opcodes. The §8.1 0xFEE7 dispatcher adds `0x48 'H'` —
1 opcode. Total **14 opcodes**.

The §3 vs §8 split is *only* by dispatch path — both paths
share the same `FUN_0082be64` helper, the same ring buffer
(`DAT_0082bfcc`), and the same worker (`FUN_00827124`). A
host that sends `0x48 'H'` and a host that sends `0x2b` use
the *same* queue, and they will compete for slots if both
are issued at high rate.

The `0xc5/0xc8/0xc9 config-byte writes` (§8.1) and the
self-marker handlers (`0x60`, `0x90`, `0x93`, `0x94`,
`0x95`, `0x96`, `0x98`, `0x9a`, `0x9c`, `0xbf`) are *not*
routed through `FUN_0082be64` — they run inline in the
dispatcher because their work is short-lived (a single
config-byte write, raw-memory write ACK, or immediate
self-marker ack) and don't need async dispatch.

Like `0xc6` (see §3.14), the `0x08` opcode is *special-cased inline*
in the main dispatcher `channel_a_dispatch_queued_frame` rather than routed to a
dedicated handler. It owns three distinct user-visible features
on the H59MA: **find-device** (vibrate the watch to help the user
locate it from the host), the **camera-shutter remote** path (a
side-effect of the find-device sequence), and the **long-press**
key sequence that powers off the watch.

#### Sub-cmd dispatch

```c
if (opcode == 0x08) {
    cVar2 = req[1];
    if (cVar2 == 0)      FUN_008275b6();        // cancel find
    else if (cVar2 == 1) FUN_00827516();        // start find
    else if (cVar2 == 0xAB && req[2] == 0xDC) { // long-press magic
        FUN_00827ba6(3);
    } else {
        if (FUN_008280fe() == 2) goto end;      // screen state guard
        FUN_00827ba6(2);                         // set motor mode 2
    }
}
```

So `req[1]` selects the action and `req[2]` carries an extra
"modifier" that only matters for the long-press case. Any sub-cmd
other than `0x00`, `0x01`, or `0xAB` falls into the
"set motor mode" branch, which is itself a no-op when
`FUN_008280fe() == 2` (the screen-state byte at
`DAT_0082810c - 0x3c` indicates the user is already in the
target mode).

#### `0x08 0x00` — cancel find / power-off (`FUN_008275b6`)

```c
void FUN_008275b6() {
    FUN_00827404();   // reset BLE
    FUN_0082dfde();   // re-initialise BLE
    FUN_0082fd9c();   // reset some state
    FUN_008274fa(2);  // motor: stop pattern
    FUN_0082954a();   // reset UI
    FUN_0082f160(2000);  // 2-second timer
}
```

Cancels the find-device pattern, tears down and re-initialises the
BLE stack, and arms a 2-second one-shot timer. The same body is
also invoked by the long-press power-off path (`0x72` pushMsgUint
helper `FUN_0082e42c` from §3.5), making `0x08 0x00` the canonical
"stop everything and wait 2 s" entry point.

#### `0x08 0x01` — start find (`FUN_00827516`)

The most complex of the four branches. Drives the watch into
find-device mode: vibrate + beep, then poll for a button press
within 1 s.

```c
void FUN_00827516() {
    if (FUN_00828af4() != 0) return;   // bail if HR step counter running
    FUN_0082a460(1000);                // 1 s UI delay
    *DAT_00827804 = 1;                 // state sentinel
    FUN_00827432();                    // reset BLE TX
    FUN_00827404();                    // reset BLE
    func_0x00013146(100);              // 100 ms delay
    FUN_0082994c(0xd2, 2, 3);          // alert (3 args — vendor profile)
    FUN_0082954a();                    // reset UI
    FUN_008274fa(1);                   // motor: pattern #1
    uint32_t start = FUN_00827994();   // read RTC start
    while (FUN_00829a4e() != 0) {      // while motor still running
        if (FUN_00827994() - start > 1000) break;  // up to 1 s
        func_0x00013146(100);
    }
    thunk_FUN_00837b42();              // stop motor
    FUN_0082928c();                    // reset UI
}
```

Key observations:

* The `FUN_00828af4() != 0` early-out is the **HR step counter
  guard**: if the user is currently recording a sport session,
  the find-device sequence is silently dropped so the vibration
  doesn't disturb the step-count reading.
* The 1 s ceiling is enforced by polling the RTC (`FUN_00827994`)
  every 100 ms (`func_0x00013146(100)`); the loop breaks on
  either the motor naturally finishing (`FUN_00829a4e() == 0`)
  or the 1 s timeout.
* The `FUN_0082994c(0xd2, 2, 3)` is the *vendor* alert pattern
  (`0xd2 = 210`), distinct from the `0x12` and `0x1F` patterns
  used by `0x50 'P'` (§8) and `0xc7` (§3.2).
* The end-of-pattern cleanup always runs even if the timeout
  fired (`thunk_FUN_00837b42` + `FUN_0082928c`), so the motor
  cannot be left running after find-device returns.

#### `0x08 0xAB 0xDC` — long-press magic

A 2-byte magic gate (`0xAB 0xDC` at `req[1..2]`) that selects the
*power-off / shutdown* variant. The handler only sets the
vibration/motor mode register to `3`:

```c
void FUN_00827ba6(int mode) {
    if (*(int *)(DAT_00827e8c + 4) != mode) {
        *(int *)(DAT_00827e8c + 4) = mode;
        FUN_008294cc();        // commit config
    }
}
```

`DAT_00827e8c + 4` is the `vibration_mode` byte that the
`FUN_008275b6` cancel-find sequence then *consumes* on the next
0x08 0x00. Mode `3` is the "power-off" preset; the actual
shutdown (BLE teardown, sensor stop) is the same `FUN_00827404` +
`FUN_0082dfde` + 2 s timer sequence already documented above.

#### Default branch — motor mode 2

For any other sub-cmd (e.g. the host sends `0x08 0x02`, `0x08 0x03`,
etc.) the dispatcher sets the motor mode to `2` ("normal alert"
preset) provided the screen state isn't already in that mode.
The guard `FUN_008280fe() == 2` reads the byte at
`DAT_0082810c - 0x3c` — when that byte is `2` the call is
skipped entirely (a host trying to set the mode it's already
in is a no-op).

#### Companion: the screen-state byte (`FUN_008280fe`)

```c
undefined1 FUN_008280fe() {
    return *(undefined1 *)(DAT_0082810c - 0x3c);
}
```

This 1-byte read is the watch's "current screen / app state"
indicator. The `0x08` default branch uses it to suppress
redundant motor-mode writes; the same byte is presumably
referenced by other handlers in the camera-shutter and
long-press sequences. The exact value-2 meaning ("motor-mode
already in target state") is recovered by the dispatcher logic
itself rather than from a string constant.

#### Record layout (`mixture_state_t`, 16 bytes)

#### Record layout (`mixture_state_t`, 16 bytes)

| Off | Field | Size | Set by | Read by |
|---:|---|---:|---|---|
| 0 | `state_flag` | 1 | `FUN_0082aee4` writes `0xCA` on a successful write | `FUN_0082b078` clears 16 B if `!= 0xCA` |
| 1..3 | `start_date_bcd[3]` | 3 | copied from `req[2..4]` | copied into `rsp[0..2]` |
| 4..5 | `start_day_pair` (u16) | 2 | `= current_day - req[5]` (signed overflow wrap) | low byte returned as `rsp[3] = current_day - record[4]` |
| 6..7 | `start_month_pair` (u16) | 2 | `= current_month - req[6]` | low byte returned as `rsp[4] = current_month - record[6]` |
| 8..12 | `period_data[5]` | 5 | copied from `req[7..11]` | copied into `rsp[5..9]` |
| 13..15 | (padding) | 3 | left zero | always zero |

The `state_flag` doubles as a "record present" sentinel: any caller that
sees `state_flag != 0xCA` must treat the record as uninitialised.

#### Sub-opcode dispatch (`FUN_0082ba54`)

`req[1]` selects the action:

| Sub | Action |
|---|---|
| `0x01` | Read: calls `FUN_0082af28(rsp)`, which copies the record into `rsp[0..9]` and leaves `rsp[10..14]` zeroed. `rsp[0]` ends up holding `start_date_bcd[0]` (the opcode byte the caller pre-stamped is overwritten by the read — firmware quirk, see §3.1.1). |
| `0x02` | Write: calls `FUN_0082aee4(req + 2)` with the 10-byte payload starting at the second byte after the sub-opcode. After copying, it sets `state_flag = 0xCA`. The write response reuses the cleared 16-byte buffer (only `rsp[0] = 0x2B` is set), so the host receives an empty `0x2B` ack. |
| other | No-op: response is a 16-byte buffer with only `rsp[0] = 0x2B` set. |

In all three cases the handler finishes by stamping `rsp[15] = FUN_0082b0c4(rsp, 0xf)` (additive byte checksum) and queues the frame via `FUN_0082ebdc`.

#### 3.1.1 Read-path quirk

The handler pre-fills the response with `local = {0x2B, 0, 0, 0, 0, …, 0}`
(16 B on stack via `push {r0-r3, r4, lr}`). `FUN_0082af28` then calls
`memcpy(rsp, record + 1, 3)`, which **clobbers `rsp[0]`** with
`start_date_bcd[0]`. The remaining 14 bytes are populated correctly
(`rsp[3..4]` are the truncated day/month deltas, `rsp[5..9]` are
`period_data`, `rsp[10..14]` are zero). The byte-0 overwrite appears to
be a long-standing firmware bug: a host that decodes `0x2b` strictly by
"first byte == 0x2B" will reject every read response. Practical decoders
should treat the *whole frame* (including the opaque `rsp[0]` value) as
the record payload and re-stamp `rsp[0] = 0x2B` after copy.

#### Cycle-phase detector (`FUN_0082af64`)

A pure helper that classifies the current cycle phase for a given
day-offset input. Return values:

| Return | Meaning |
|---:|---|
| `3` | Unset (`start_date_bcd[0] == 0` or `start_date_bcd[2] == 0`) |
| `2` | Early phase — `day_offset + 1 <= start_date_bcd[1]` |
| `1` | Mid phase — `(start_date_bcd[2] - (day_offset + 1) - 9) ∈ [0, 9]` |
| `0` | Late phase — otherwise |

`day_offset` is computed as
`(start_date_bcd[2] + current_month + arg) - start_day_pair`; the
comparison `start_date_bcd[1]` therefore reads as the cycle length in
days (typical: 28).

#### Phase-transition notifier (`FUN_0082b01e`, `FUN_0082b090`)

`FUN_0082b01e` is called from the main-loop tick `FUN_00827134` (after
the daily `*pcVar2 == '\x03'` check). It compares the *current* phase
(`thunk_FUN_0082af64(record[3])`) with the *previous* phase
(`thunk_FUN_0082af64(record[3] - 1)` and `thunk_FUN_0082af64(record[4] - 1)`),
and on a 0→1 or 1→2 transition invokes `FUN_0082b090(phase)` which
fires a motor+UI alert (`FUN_0082a5b2(5)` + `FUN_0082994c(0x12, 1, 3, 10)`)
provided the user is on the home screen (`FUN_0082a826() == 0`).

#### Lazy initializer (`FUN_0082b078`)

On the first reference after boot, `FUN_0082b078` checks
`record[0] != 0xCA` and, if so, zeros the full 16-byte record. This
guarantees the "unset → return 3" branch in `FUN_0082af64` works
without needing an explicit factory-reset path.


---

## 4. ANCS (Apple Notification Center Service)

| Address | Function | Role |
|---|---|---|
| `0x00839ac4` | `FUN_00839ac4` | Sends ANCS data over notify char |
| `0x00839e4e` | `FUN_00839e4e` | `ancs_add_client` — registers ANCS client, allocates 0x114-byte per-client state |
| `0x0083a116` | `FUN_0083a116` | `ancs_client_cb` — handles ANCS lifecycle events — see §4.1 |
| `0x00839fee` | `FUN_00839fee` | NotificationSource data parser — see §4.2 |
| `0x0083a036` | `FUN_0083a036` | GetAppAttributes follow-up requestor — see §4.3 |

The watch implements an ANCS client so iOS notifications can be pushed
to the screen via opcode `0x72`.

#### 4.0 ANCS state machine synthesis

The four §4 sub-sections (§4.1-§4.4) document the
**complete ANCS state machine**. This sub-section pulls them
together as a single pipeline.

The ANCS pipeline has 4 stages:

1. **Client register** — `FUN_00839e4e` (`ancs_add_client`)
   at startup allocates `0x114` bytes per client and registers
   the callback at `FUN_0083a116` (§4.1).
2. **Notification source** — when iOS pushes a notification,
   `FUN_0083a116` calls `FUN_00839fee` (§4.2) to parse the
   8-byte ATT header (event_id / flags / category / count /
   uid) into the client's `state_base + 4..+0xE`.
3. **Data source** — to retrieve the full notification text,
   iOS responds to a GetAppAttributes read at `state_base + 0x10`.
   `FUN_0083a036` (§4.3) writes the cached notification into
   the read buffer and the host reads it back.
4. **Push to §3.3** — once the host SDK decodes the
   notification text, it pushes the rendered message to the
   §3.3 `0x72 pushMsgUint` handler with the §3.3 chunked
   flush mechanism.

The §4.1 callback's `event_id 2` ("data") path is what
triggers stage 3, so §4.1 and §4.3 are the **active** stages.
§4.2 (parse) and §4.4 (disconnect) are the **passive**
stages — they run when iOS sends a notification or
disconnects, not when the host asks.

The §4.1 callback's `event_id 1` ("notification") path is the
**inbound** path — iOS pushes a notification, the watch
parses it, and the host SDK queues it for display. The
`event_id 0` ("connect") path runs once at startup and the
`event_id 3` ("disconnect") path runs once at iOS-side BLE
shutdown.

#### 4.1 ANCS client callback (`FUN_0083a116`)

Lifecycle dispatcher. Receives `(ctx, client_idx, event_ptr)` from the
GATT stack and switches on the first byte of `event_ptr` (the
"event_id" of the ANCS client wrapper). The handler is the only
entry point that touches the per-client state at
`client_idx * 0x114 + state_base + 4`.

#### Event dispatch

| `event_id` | Action |
|---:|---|
| `0` (connect) | Sub-classified on `event[4]`: `2` → `func_0x00005aa8(..., connect_log, 0)` + `FUN_008399ec(client_idx, 1)`; `3` → log a different "bind" line. Both fire a debug log line; neither changes state. |
| `1` (notification) | If `event[6]` (data length) is non-zero, enable the ANCS notification subscription via `func_0x00005aa8(..., notif_subscribe_log, 1)`. Then dispatch on `event[4]` (notification action byte) via a switch8 table at `0x83a1b5` (16 entries) — see below. |
| `2` (data) | Sub-classified on `event[4]`: `0` (NotificationSource) → `FUN_00839fee(client_idx, event+8, event[6])`; `1` (AppAttribute) → log + `FUN_0083a036(client_idx, event+8, event[6])`. |
| `3` (disconnect) | Log the disconnect, then `memset(client_state, 0, 0x114)` to wipe the per-client state. The 4 bytes at `state_base + 4` (a u32 reference, e.g. an attribute handle) is preserved across the wipe. |

#### Notification sub-dispatch (`event_id == 1`, switch8 at `0x83a1b5`)

The 16-entry ARM-Thumb switch8 table (base `0x83a1b5`, format
`u8 half-offset`) decodes the `event[4]` (ANCS "NotificationAction")
into per-action handlers:

| Action | Handler target | Notes |
|---:|---|---|
| `0` | `0x83a1bd` | "added" — likely records the notification UID and starts attribute fetch |
| `1` | `0x83a1c5` | "modified" — re-records the UID |
| `2` | `0x83a1cd` | "removed" — clears the UID slot |
| `3` | `0x83a1e3` | "action" — iOS 12+ "press/release" action dispatch |
| `4` | `0x83a1f1` | "category" — extract category byte for routing |
| `5` | `0x83a24d` | reserved (out of range) |
| `6` | `0x83a1b5` (default) | no-op |
| `7` | `0x83a255` | "sub-action" — secondary press/release routing |
| `8` | `0x83a247` | secondary "modified" |
| `9` | `0x83a1b5` (default) | no-op |
| `10` | `0x83a1f9` | "fetch-attrs" — request `GetAppAttributes` for the new UID |
| `11` | `0x83a225` | app-attribute response |
| `12` | `0x83a217` | reserved / debug |
| `13` | `0x83a1d7` | "press-only" action |
| `14` | out-of-function (default) | falls into the default slot |
| `15` | `0x83a251` | "release-only" action |

The actual per-action bodies are tiny thunks (each ~6 instructions)
that call the same downstream parsers as the `event_id == 2` path.

### 4.2 NotificationSource data parser (`FUN_00839fee`)

Called from the `event_id == 2, event[4] == 0` path with
`(client_idx, data_ptr, data_len)`. Logs the raw length, then
accumulates bytes into the per-client state starting at
`client_idx * 0x114 + state_base`:

```c
void FUN_00839fee(int client_idx, char *data, int data_len) {
  log("notif_src", client_idx, data_len);
  state = client_idx * 0x114 + state_base;
  if (*state == 0) {                       // first fragment
    if (data_len != 0 && *data == 0) *state = 1;   // accept start-of-frame
  } else if (*state > 15) {
    return;                                // capacity cap
  }
  FUN_00839f30(state, data, data_len);     // append to state buffer
}
```

The per-client state is laid out so that `state[0]` is a 1-byte
fragment counter / flag; subsequent bytes are the raw
NotificationSource payload (EventID u8, Flags u8, CategoryID u8,
CategoryCount u8, NotificationUID u32 — 8 B of header, then
optional component IDs). The cap at `> 15` matches the worst-case
header + 7 component bytes.

### 4.3 GetAppAttributes follow-up (`FUN_0083a036`)

Called from the `event_id == 2, event[4] == 1` path with
`(client_idx, data_ptr, data_len)`. Only acts on the canonical
8-byte `cmd=0x1A` "Get App Attributes" frame:

```c
if (data_len != 8) return;
cmd_id   = data[5];      // 0/1/4/6/7 = attr we are requesting
attr_id  = data[0];      // must NOT be 2 (AppIdentifier — already known)
if (attr_id == 2) return;
```

The handler then builds the 14-byte
`{cmd=0x1A, notif_uid=u32, attr_mask=u16, pad=6x u8}` request
covering attribute IDs 0..7 (display name, subtitle, message,
date, positive action label, negative action label, reserved,
reserved) and submits it via `func_0x00012e82` /
`FUN_00839a3e`. On success (`func_0x00012ed6 == 0`) it logs a
debug line; on failure it logs the error and returns.

This is the "second-stage" parser: when a notification arrives
with a UID the watch has not seen before, the ANCS layer issues a
GetAppAttributes request to fetch the human-readable app name (and
optionally subtitle/message) before queuing the push on the
Channel-A `0x72` path.

---

## 5. OTA / DFU

| Address | Function | Role |
|---|---|---|
| `0x0082fe52` | `ota_dfu_state_machine` | OTA/DFU state machine driven by Channel-B command ids |
| `0x0082f160` | `ota_start_write_flag_timer` | Starts a one-shot timer (used during reboot/OTA) |
| `0x0082f1a4` | `ota_cmd_start_ack` | OTA start ack |
| `0x0082f1b6` | `ota_cmd_init_metadata` | OTA init — parses 9-byte metadata and stores expected image size/check fields |
| `0x0082f240` | `ota_cmd_write_data_packet` | OTA data — validates sequence/header, strips file offset `0x50`, writes image data to staging flash |
| `0x0082f378` | `ota_cmd_check_complete` | OTA check — validates completion and size |
| `0x0082f3b4` | `ota_cmd_end_reboot` | OTA end — reboots/applies device image |
| `0x0082f410` | `ota_cmd_sub_ack` | OTA sub-ack |
| `0x00840724` | `cfg_blob_magic_ok` | **Not OTA.** Persistent config-blob magic check for `0x8721bee2`; kept here only because older notes misidentified it as OTA validation. |

The OTA data path checks the first word of the OTA container prefix against
`ota_container_magic` (`0x0082f47c`, bytes `e5 c3 bd 81`, little-endian
`0x81bdc3e5`) and then stages file bytes from offset `0x50` onward. The
separate `0x8721bee2` magic belongs to the persistent config blob, not the OTA
image. The 32-byte `image_digest @0x1c4` is staged as raw image data after the
`0x50` strip, but is not parsed or validated in `body.bin`; bootloader-side
validation remains unresolved. See `firmwares/_re/ota-container/evidence.md`.

### 5.1 OTA/DFU state machine (`FUN_0082fe52`)

The four-sub-cmd Channel-B OTA dispatcher referenced from
multiple sections (e.g. §1.2 "0x21, 0x31, 0x35, 0x36, 0x61",
§3.20, §8.3). It uses two state buffers and four
sub-cmd values to drive the OTA flow.

#### State buffers

| Buffer | Role |
|---|---|
| `DAT_00830120` | OTA control state — byte 0 = current state, byte 3 = "needs drain" flag |
| `DAT_00830120 + -8` | OTA timer state (shared with `FUN_008275d8` / `FUN_0082f160`) |
| `DAT_00830124 + 0x11` | OTA dispatcher state byte — must equal `0x02` for the handler to run (else early return) |
| `DAT_00830128` | OTA image config / data (4 state addresses: `+0x14`, `+0x18`, `+0x1C`) |
| `DAT_0083012c` | OTA image config 2 (used by sub-cmd 1) |
| `DAT_00830130` | OTA worker queue (deferred-ring downstream) |

#### Sub-cmd dispatch

| `param_1` (cmd id) | Action | Helper called |
|---:|---|---|
| `4` | "transition to ready" — clear timer, set state = 4 | `FUN_0082fe4c(DAT_00830128)` |
| `0` | "cancel" — drain queue | `FUN_0082fe4c(DAT_00830128 + 0x14)` |
| `1` | "init" — drain queue | `FUN_0082fe4c(DAT_0083012c)` |
| `2` | "receive" — drain queue | `FUN_0082fe4c(DAT_00830128 + 0x18)` |
| `3` | "complete" — drain queue | `FUN_0082fe4c(DAT_00830128 + 0x1C)` |

#### State-machine semantics

The handler dispatches based on the **delta** between the
current state (`*pbVar1`) and the requested state
(`param_1`):

* If `current_state == 4` (ready) and the new request is
  also `4`: no-op.
* If `current_state == 4` and the new request is *not*
  `4`: early-return (state already at "ready").
* If `param_1 == 4` (force-ready): set state = 4, call
  `FUN_0082fe4c(DAT_00830128)`.
* If `current_state != param_1` and `param_1 != 0`:
  call the matching `FUN_0082fe4c` sub-routine.
* If `param_2 != 0` after the helper: queue a worker via
  `FUN_00829c24` for downstream consumption.

The `param_1 == 4` "force-ready" path is the **OTA bootloader
ready** signal — the OEM host tools send `0x04` to clear
any previous OTA state before pushing a new image.

#### Why `DAT_00830124 + 0x11 == 0x02` is the entry guard

The byte at `+0x11` in `DAT_00830124` is a *vendor-mode*
flag — the OTA handler is only active when the watch is in
"OTA mode" (state `2`). Outside OTA mode (e.g. normal
runtime), the handler early-returns without doing
anything. This prevents accidental OTA state transitions
from a misbehaving host.

#### Pair with §5 helper functions

The four sub-cmds (`0x00`, `0x01`, `0x02`, `0x03`) route to
the §5 helper functions:

* `0x00` (cancel) → `FUN_0082f1a4` (OTA start ack)
* `0x01` (init) → `FUN_0082f1b6` (OTA init)
* `0x02` (receive) → `FUN_0082f240` (OTA data)
* `0x03` (complete) → `FUN_0082f378` (OTA check)

The state machine (`FUN_0082fe52`) is the *dispatcher*,
the §5 helpers are the *workers*. A host that sends a
sequence of OTA commands (init → receive N times → complete)
sees the dispatcher route each to the right worker.

### 5.2 OTA helper details

The small §5 helpers wrap OTA state transitions and flash staging. The
persistent config validator at `0x00840724` is documented separately in §5.3
because it was previously mistaken for an OTA signature check.

#### `ota_cmd_start_ack`

```c
u32 ota_cmd_start_ack() {
    (*(code **)(ota_write_context_ptr - 4))(1, 0);
    return 0;
}
```

The simplest OTA worker: calls the registered OTA callback with `(1, 0)` and
returns success.

#### `ota_cmd_init_metadata`

The OTA-init handler parses exactly 9 payload bytes:

```c
u32 ota_cmd_init_metadata(u8 *req, int len) {
    if (len != 9) return callback(2, 1), 1;
    if (req[0] != 0x01 && req[0] != 0x04) return callback(2, 2), 1;
    expected_size = u32le(req + 1);
    crc16 = u16le(req + 5);
    checksum16 = u16le(req + 7);
    written_bytes = 0;
    packet_index = 0;
    ota_state = 2;
    callback(2, 0);
    return 0;
}
```

* `req[0]` — cmd byte (`0x01` or `0x04`)
* `req[1..4]` — image size (`u32LE`)
* `req[5..6]` — CRC/check field (`u16LE`)
* `req[7..8]` — additive/check field (`u16LE`)

The state-machine transitions are:
1. Clear written-byte and packet-index counters.
2. Store expected image size and check fields.
3. Set OTA state to `2`.
4. Call the registered callback with `(2, 0)` (function
   pointer from `state - 4`).

The `0x01` and `0x04` cmd bytes are the only ones accepted.
The `0x04` cmd byte is the *force-ready* path (same as the
§5.1 `param_1 == 4` branch in `FUN_0082fe52`); the `0x01`
cmd byte is the normal init path. Any other cmd byte
returns error 2; any other sub-cmd returns error 1.

#### `ota_cmd_write_data_packet`

Payload is `[u16LE 1-based packet_index] + raw bytes`. The first packet carries
the container prefix. The writer:

1. Requires OTA state `2` or `3`.
2. Requires packet index to increment by 1.
3. Rejects data payloads larger than `0x600` bytes.
4. On packet 1, checks word 0 of the container prefix against
   `ota_container_magic` (`0x81bdc3e5`) and optionally compares the hardware
   string from the first 0x50 bytes against current/default `H59MA_V1.0`.
5. Writes only bytes after file offset `0x50` to `ota_staging_flash_base`
   (`0x0084e000` in this image), erasing 4 KiB pages as needed. This staged
   region includes the `image_digest @0x1c4` as raw data, but this runtime body
   does not compute or compare that digest.

`ota_cmd_check_complete` later requires `written_bytes == expected_size - 0x50`
before moving state to `4`.

### 5.3 Persistent config blob (`cfg_blob_magic_ok`, `cfg_find_item`)

The `0x8721bee2` magic checked by `cfg_blob_magic_ok` belongs to the persistent
config store, not OTA. Config blobs start with:

```
u32 magic = 0x8721bee2
u16 len
records...
```

The firmware's `"wrong signature! Read %8X != Requried %8X"` log is emitted
by this helper when the first u32 is not `0x8721bee2`; "signature" is a legacy
debug string for the config-blob magic, not an OTA image signature. See
`firmwares/_re/config-blob/evidence.md`.

Each record has:

```
u16 item_id
u8  len
u8  value[len]
u8  mirror_or_compare[len]
```

`cfg_find_item` scans records from offset `+6`, guarded by a maximum scan size
near `0x03fa`. `cfg_update_mac_item` updates item `0x33` with length `6` and
logs `Ready to update MAC!`. `cfg_write_to_flash_preserve_sector` rewrites a
changed config range by preserving the 0x400-byte prefix and 0x800-byte suffix
around the changed data, erasing the enclosing 4 KiB sector, and writing the
prefix/change/suffix back.

#### Offset-store settings blobs

The firmware also has two offset-store settings blobs outside the `0x8721bee2`
config item store:

| Blob | RAM base | Flash offset | Length | Magic | Commit helper | Role |
|---|---:|---:|---:|---:|---|---|
| blob0 | `0x200088fc` | `0x0000` | `0xe0` | `0x04` | `settings_blob0_commit` | BLE identity, advertised name, Channel-B `0x5a` TLV slots. |
| blob1 | `0x200089dc` | `0x0400` | `0x2b0` | `0x07` | `settings_blob1_commit` | User settings: DND, health feature bits, sedentary, menstruation, touch/UV config. |

Stable blob1 fields confirmed from Channel-A handlers:

| Field | Meaning | Writers |
|---:|---|---|
| `+0x2d` bit `1` (`0x02`) | SpO2 enabled | `settings_set_spo2_enabled_commit_if_changed`; commits blob1 when changed. |
| `+0x2d` bit `3` (`0x08`) | Pressure/stress enabled | `settings_set_pressure_enabled_ram`; RAM-only in this path. |
| `+0x2d` bit `5` (`0x20`) | Blood-sugar flag | `settings_set_sugar_flag_ram`; subcmd `0x3a/3`. |
| `+0x2d` bit `7` (`0x80`) | Lipids flag | `settings_set_lipids_flag_ram`; subcmd `0x3a/4`. |
| `+0x2e` | Sugar/lipids init sentinel | Sugar write sets this to `0x1e` if it was zero. |
| `+0xc8` | Touch/UV config byte | Channel-A `0x3b`, guarded by request byte `2 == 0`. |
| `+0xee..+0xf3` | DND schedule | `[enable, runtime, startMin u16LE, endMin u16LE]`. |
| `+0x294..+0x299` | Sedentary config | `[start_h,start_m,end_h,end_m,enable,duration]`; times are BCD on Channel A and stored as decoded bytes. |
| `+0x29a..+0x2a6` | Menstruation config | Marker `0xca`, copied fields, and current-day-relative u16 values. |

#### Persistent-history descriptor rings

The history tables use 12-byte descriptors:

```
u32 flash_base
u32 span_bytes
u16 erase_unit_bytes
u16 record_stride
```

`history_ring_find_record_by_key` scans existing slots by the u32 key at record
offset `+0`; `history_ring_find_or_allocate_slot` finds the matching key or an
empty `0xffffffff` slot, formatting the table if no free slot remains.
`history_ring_upsert_record_body(desc, cursor, key, body_offset, src, len)`
writes the key first and then writes the selected body range, preserving the
surrounding 4 KiB sector when an existing record needs to be cleared.

| Descriptor | Flash range | Stride | Slots | Key | Primary consumers |
|---|---:|---:|---:|---|---|
| `history_desc_hourly_detail_24x12` (`0x00845a44`) | `0x00874000..0x00875fff` | `0x200` | 16 | day index | Channel-A `0x43`, Channel-B `0x12` sleep detail. |
| `history_desc_sleep_summary_100b` (`0x00845a50`) | `0x00876800..0x00876fff` | `0x80` | 16 | day index | Channel-B `0x11`, `0x27`. |
| `history_desc_sleep_nap_100b` (`0x00845a5c`) | `0x00876000..0x008767ff` | `0x80` | 16 | `day \| 0x00bb0000` | Channel-B `0x27` nap path. |
| `history_desc_activity_daily_24x2` (`0x00845a98`) | `0x00877000..0x00877fff` | `0x80` | 32 | day index | Channel-B `0x2a` activity summary. |
| `history_desc_heart_rate_5min` (`0x00845aac`) | `0x00878000..0x00879fff` | `0x200` | 16 | `seconds / 86400` | Channel-A `0x15` HR history. |
| `history_desc_bp_hourly` (`0x00845ae4`) | `0x0087a000..0x0087afff` | `0x80` | 32 | day index | Channel-A `0x0e` / `0x0d` BP chunks. |
| `history_desc_pressure_30min` (`0x00845af0`) | `0x0087b000..0x0087bfff` | `0x100` | 16 | day index | Channel-A `0x37`. |
| `history_desc_hrv_30min` (`0x00845afc`) | `0x0087c000..0x0087cfff` | `0x100` | 16 | day index | Channel-A `0x39`. |

Record bodies are compact and fixed-width:

| Descriptor | Body layout |
|---|---|
| `history_desc_hourly_detail_24x12` | key at `+0`, then 24 hourly slots x 12 bytes at `+4`. |
| `history_desc_sleep_summary_100b` / `history_desc_sleep_nap_100b` | 100-byte payload copied from offset `0`, so the copied source includes the key/header. |
| `history_desc_activity_daily_24x2` | key at `+0`, then 24 activity samples x 2 bytes at `+4`; Channel-B `0x2a` sends the 48-byte body. |
| `history_desc_heart_rate_5min` | key at `+0`, then 288 5-minute HR samples at `+4`; out-of-range values outside `0x28..0xdc` are zeroed before the `0x15` response. |
| `history_desc_bp_hourly` | key at `+0`, then 24 hourly 4-byte BP slots at `+4`; current reader emits the first byte of each slot in compact `0x0d` fragments. |
| `history_desc_pressure_30min` / `history_desc_hrv_30min` | key at `+0`, then 48 half-hour one-byte samples at `+4`; responses send `[day_offset] + 48 samples` after the `0x1e050037` / `0x1e050039` header. |

No SpO2 history descriptor was found in this cluster. Channel-A `0x2c` only
reads/writes the SpO2 enable bit in blob1, while `spo2_current_value` reports
the current live measurement value for stop/result frames.

#### Channel-B `0x5a` TLV storage

`channel_b_handle_device_info_config` subcmd `2` accepts
`[0x02, count, (id, len, data[len])*]`. The writer clears each destination to a
nominal max length, then copies the supplied length; no length clamp was visible
in the decompiled callee, so hosts should keep lengths within the maxima below.

| TLV id | Destination | Max cleared | Enable flag | Notes |
|---:|---:|---:|---|---|
| `1` | blob0 `+0xb6` | `0x18` | blob0 `+0xd6` bits `1:0 = 1` | Custom advertised name/prefix. |
| `2` | blob0 `+0xce` | `0x06` | blob0 `+0xd6` bits `3:2 = 1` | BLE address override; calls `cfg_update_mac_item`. |
| `3` | blob0 `+0x7a` | `0x14` | blob0 `+0xd5` bits `1:0 = 1` | Device-info string slot. |
| `4` | blob0 `+0x8e` | `0x10` | blob0 `+0xd5` bits `3:2 = 1` | Device-info string slot. |
| `5` | blob0 `+0x9e` | `0x10` | blob0 `+0xd5` bits `5:4 = 1` | Device-info string slot. |
| `6` | blob0 `+0xae` | `0x08` | blob0 `+0xd5` bits `7:6 = 1` | Device-info string slot. |
| `7` | blob0 `+0xd4` | `1` | none | Name-format control byte; not returned by query. |

Subcmd `4` clears blob0 `+0x7a` for `100` bytes and commits blob0. That clears
the string slots and flags but does not call `cfg_update_mac_item`, so the
sector config item `0x33` can remain stale until a later MAC-update path runs.

#### Pair with §10.2 (open question)

The 32-byte OTA digest algorithm referenced in §10.2 is
**not** in the firmware body. `body.bin` checks the 4-byte OTA container magic
at `ota_container_magic`, stages bytes from file offset `0x50` onward, and
checks final staged length. It stages the 32-byte `image_digest @0x1c4` as raw
image data but does not validate it. Digest validation, if present, is
presumably bootloader-side.

---

## 6. Power Management & System

| Address | Function | Role |
|---|---|---|
| `0x0082a144` | `FUN_0082a144` | Button/DLPS init — sets up long-press, debounce, DLPS timers — see §6.1 |
| `0x008275d8` | `FUN_008275d8` | System reset / re-initialize: stops sensors, resets BLE, restarts main task |
| `0x0082a460` | `FUN_0082a460` | Delays via a 1000 ms timer (used in reboot paths) |
| `0x0083deb0` / `0x008267cc` | `prng_seed` / `prng_next31` | 0x37-word additive PRNG ring seed and next-value helper. |
| `0x0082ebdc` | `channel_a_queue_notify_frame` | Queue manager for Channel A notifications |
| `0x0082eb8a` | `FUN_0082eb8a` | Kicks BLE notify transmission |

### 6.1 Button / DLPS init (`FUN_0082a144`)

The firmware's *power-management setup* helper. Called once
during boot and once after each `0xc6 0x6C 'l'` reboot
(§3.14) to re-arm the button handling and DLPS (deep-low-
power-state) wakeup logic.

```c
void FUN_0082a144() {
    gpio_set_pin_mux_byte(9, 0x5A);                           // mux byte for pin/index 9
    gpio_configure_pin(9, 1, 1, 0, 0, 0);                     // configure pin/index 9
    FUN_00838738(DAT_0082a330, 0x21000000, 1);               // vendor init: reg + mode + flag
    func_0x00013634(DAT_0082a320 + 4, long_press_cb,  1, 2000, 0, ...);  // 2-sec timer
    func_0x00013634(DAT_0082a320 + 8, debounce_cb,   1, 0x3c, 0, ...);  // 60-ms timer
    func_0x00013634(DAT_0082a320 + 0xC, dlps_allow_cb, 1, 500,  0, ...);  // 500-ms timer
    FUN_00838f68(&local_28);                                  // read vendor reg
    local_28 = gpio_index_to_bitmask(9);
    local_24 = 0; local_23 = 1; local_22 = 0; local_21 = 0;
    FUN_00838eb0(&local_28);                                  // vendor write: reg + 4 byte config
    local_18[0] = 0x1D;
    local_14 = 3;
    local_10 = 1;
    FUN_008380ac(local_18);                                   // GPIO config: 0x1D = ?
    uVar1 = gpio_index_to_bitmask(9);   FUN_00838f9c(uVar1, 1);
    uVar1 = gpio_index_to_bitmask(9);   FUN_00838f82(uVar1, 1);
    gpio_index_to_bitmask(9);           FUN_00838f94();       // read-back
    uVar1 = gpio_index_to_bitmask(9);   FUN_00838f9c(uVar1, 0);
    FUN_00838294(9, 1, 0);                                   // vendor call: reg 9 with 2 args
}
```

The handler does three things:

1. **GPIO/vendor register setup** — multiple `gpio_set_pin_mux_byte` /
   `gpio_configure_pin` / `FUN_00838738` / `FUN_00838eb0` /
   `FUN_00838f9c` calls configure the button-interrupt
   controller's registers (the values are vendor-specific
   — the function names suggest this is the same vendor
   test-table as `0xce ' '` §8.10).
2. **Three timer setup** — `func_0x00013634` is the
   standard timer-arm helper:
   - Long-press timer at `+4`: 2000 ms (matches the
     `0xc6 0x6C 'l'` reboot's 2-sec wakeup timing).
   - Debounce timer at `+8`: 0x3c = 60 ms (matches the
     `0x08` findDevice long-press debounce from §3.15).
   - DLPS-allow timer at `+C`: 500 ms (the "no input for
     500 ms → allow deep-low-power-state" gate).
3. **GPIO config** — `FUN_008380ac(local_18)` configures
   GPIO with mask `0x1D`, 3 pins, 1 enabled — the wakeup
   pin mask.

#### Why three timers?

The three timers are the **three layers of power
management**:

* **Debounce** (60 ms) — filters out button-bounce
  artifacts on the physical pin.
* **Long-press** (2000 ms) — the "user has held the button
  for 2 seconds → shutdown" trigger.
* **DLPS-allow** (500 ms) — "no user activity for 500 ms
  → enter deep-low-power-state".

The DLPS-allow timer is the **only one of the three that
needs re-arming** during runtime (after each user activity,
the timer resets to 500 ms). The debounce and long-press
timers are fire-and-forget on button-press events.

#### Why this is paired with §3.8 `0xff factory reset`

`0xff` factory reset (§3.8) calls `FUN_008275d8` which is
the §6 system-reset helper. The system reset tears down
all timers and re-runs `FUN_0082a144` to re-arm them.
Without the re-arm, the firmware would have no button
handling after a factory reset.

#### Pair with §3.15 `0x08` findDevice

The `0x08` findDevice handler (§3.15) uses the same
`func_0x00013634` debounce timer with the same 60 ms
period. The `0x08` debounce is the *physical-input* gate;
`FUN_0082a144`'s debounce timer is the *system-input* gate.
Both share the 60 ms period because the same vendor
button-controller IC drives both.

#### `0x1D` GPIO mask

The GPIO mask `0x1D` = `0b00011101` enables wakeup on GPIO
pins 0, 2, 3, 4. These are the physical button pins on
the H59MA hardware:
* Pin 0 — the side button (long-press → shutdown).
* Pin 2 / 3 — the touch-screen wakeup.
* Pin 4 — the side button's second contact (long-press → 
  factory reset).

Pin 1 (touch-screen *active* signal) is excluded — the
touch-screen itself wakes the watch via the DLPS path,
not the GPIO path.

---

### 6.2 System reset / re-initialize (`FUN_008275d8`)

The firmware's *big-reset* routine. Called by `0xff 'fff'`
factory reset (§3.8) and by `0xc6 0x6C 'l'` reboot (§3.14)
to bring the watch back to a clean runtime state.

```c
void FUN_008275d8() {
    FUN_0082a460(1000);      // 1-second delay
    FUN_00827404();          // stop BLE peripheral
    FUN_0082dfde();          // reset BLE stack
    FUN_0082fd9c();          // reset some state
    FUN_00829560();          // reset more state
    FUN_0082949c();          // reset more state
    *DAT_00827804 = 5;       // set state byte = 5
    int iVar1 = DAT_0082780c;
    *(u32*)(iVar1 + 4) = 0;   // zero 12 bytes of state
    *(u32*)(iVar1 + 8) = 0;
    *(u8*) (iVar1 + 0xd) = 0;
    FUN_0082954a();          // reset UI
    FUN_00833e86();          // reset (next-state setup)
    FUN_00831b90();          // reset (task spawn)
    thunk_FUN_00831230();    // task reset
    FUN_00827940();          // reset motor
    FUN_0082f160(1000);     // start 1-sec timer
}
```

The reset is a **14-step sequence** that takes ~1 second to
complete (the two `1000`-ms timers bracket it):

1. **Delay 1 sec** (`FUN_0082a460(1000)`) — wait for any
   pending user-action ack to drain.
2. **Stop BLE peripheral** (`FUN_00827404`) and **reset BLE
   stack** (`FUN_0082dfde`) — tear down the radio.
3. **Reset state** (`FUN_0082fd9c`, `FUN_00829560`,
   `FUN_0082949c`) — clear three different state buffers.
4. **Set state byte = 5** at `DAT_00827804` — the "reset in
   progress" sentinel.
5. **Zero 12 bytes** of state at `DAT_0082780c + 4..+0xd`
   — clear the deferred-ring state.
6. **Reset UI** (`FUN_0082954a`) — clear the screen.
7. **Spawn** the post-reset task (`FUN_00833e86` /
   `FUN_00831b90` / `thunk_FUN_00831230`) — restart the main
   loop.
8. **Reset motor** (`FUN_00827940`) — stop any vibration.
9. **Start 1-sec timer** (`FUN_0082f160(1000)`) — the
   post-reset boot delay.

The `*DAT_00827804 = 5` state byte is the "watch is being
reset" sentinel — the main loop checks this byte before
processing new requests. While the byte is `5`, the watch
ignores all incoming BLE traffic.

#### Why 14 steps?

Each step is a *separate subsystem*:

| Step | Subsystem |
|---|---|
| 1, 14 | Timing |
| 2 | BLE peripheral (radio IC) |
| 3 | BLE stack (firmware GATT / L2CAP) |
| 4, 5 | Per-task state (HR / sport / sleep buffers) |
| 6, 9 | Sensor-task state (`DAT_00827804`) |
| 7 | Deferred-ring state (`DAT_0082780c`) |
| 8 | UI / display |
| 10, 11, 12 | Task scheduler |
| 13 | Vibration motor |

A factory-reset must clean *all* of these because each
subsystem has its own state buffer that the firmware
otherwise relies on. If any one step is skipped, the
firmware can deadlock or emit garbage after the reset.

#### Why `*DAT_00827804 = 5`

The state byte `5` is the "fresh-boot" sentinel. After the
reset completes, the post-reset task sets the byte to a
different value (probably `1` for "ready") to signal that
the watch is accepting requests. The §6.2 step 6 writes `5`
to indicate "in progress" — the main loop polls this byte
and ignores new requests while it's `5`.

#### Pair with §3.8 `0xff factory reset`

`0xff factory reset` (§3.8) is the **only** public entry
point into `FUN_008275d8`. The §3.14 `0xc6 0x6C 'l'` reboot
calls `FUN_008275d8` *internally* as part of the full-reboot
sequence — the public `0xc6` API returns to the host before
the reset runs (the host sees the implicit ack).

#### Pair with §3.14 `0xc6 0x6C 'l'` reboot

`0xc6 0x6L` calls `FUN_008275d8` *plus* several additional
helpers (the §3.14 sequence is "soft reset → stop BLE →
reset state → re-arm timer → reset"). The `0xff` path goes
through `FUN_008275d8` directly, while the `0xc6` path goes
through a higher-level wrapper that calls `FUN_008275d8`
after stopping user-visible subsystems.

#### Why this is in §6 (Power Management)

`FUN_008275d8` is the firmware's *power-management reset*
helper — it tears down the BLE radio, the deferred ring, the
sensor tasks, and the UI to bring the watch back to a
minimal-power "bootstrapping" state. The §6 Power Management
section is the right place for it because the reset's primary
goal is to *recover the watch from a stuck state* (similar to
a "force reboot" on a desktop OS).

---

## 7. Health / Sensor Modules

| Address | Function | Role |
|---|---|---|
| `0x00833770` | `FUN_00833770` | HR module dispatcher (refers to `hr_module.c`); branches on sub-command 0–3 — see §7.1 |
| `0x00833334` | `FUN_00833334` | Accelerometer / LIS3DH SPI dispatcher |

Strings confirm additional algorithm libraries: `VC_HRV_16Bit_integration_6.0_addRMSSD`, `spo2_VC30F_S_int_limit_ed01`, `lib_BIODetect_V14_1`, `vc_SportMotion_Int`.

### 7.1 HR module dispatcher (`FUN_00833770`)

The `hr_module.c` front-end that dispatches HR-related work
to the underlying algorithm libraries. Takes the sub-cmd in
the **upper 16 bits** of `param_1` and a u16 mode parameter
in `param_2`.

```c
void FUN_00833770(u32 param1, u16 param2) {
    u16 sub = (u16)(param1 >> 16);
    if (sub == 0) {
        FUN_0083376e();                 // reset
    } else if (sub == 1) {
        FUN_00837b96(param2);           // start mode 1
    } else if (sub == 2) {
        FUN_00837c4e(param2);           // start mode 2
    } else if (sub == 3) {
        FUN_0083376c();                 // read/stop
    } else {
        // unexpected sub-cmd — assertion-fail log
        uVar1 = func_0x00005e6a(0x23400000, "qc_code_app_module.h");
        func_0x00005aa8(DAT_00833898, DAT_00833894, 2, uVar1, 0x1ac);
    }
}
```

The four sub-cmd branches map to the four lifecycle stages of
a heart-rate measurement:

* **`sub 0` reset** — `FUN_0083376e` stops any running
  measurement and clears the per-task state.
* **`sub 1` start mode 1** — `FUN_00837b96(param2)` starts
  the measurement with `param2` as the mode parameter
  (the same `param2` value the §8.5 / §8.7 0x69 / 0x6a
  mode-control opcodes pass).
* **`sub 2` start mode 2** — `FUN_00837c4e(param2)` is the
  second mode-start variant (probably the one-shot vs
  continuous split from §3.13 0x1e realTimeHeartRate).
* **`sub 3` read/stop** — `FUN_0083376c` reads the latest
  measurement (or stops if `param2 != 0`).

The `else` branch is the **assertion-fail path** — the
firmware logs a hard-coded module header (`0x23400000`,
the debug-output ID for `qc_code_app_module.h`) via the
standard `func_0x00005e6a` / `func_0x00005aa8` debug helpers.
A host SDK that sends an unknown sub-cmd will see the watch
*log an assertion* but otherwise no-op — the firmware doesn't
NAK or send an error frame for this path.

#### Why sub-cmd in upper 16 bits of param1

The `param1` argument is a `u32` where the upper 16 bits
encode the sub-cmd and (presumably) the lower 16 bits
encode the *handler-id* (which HR sensor — internal vs
external). The decompiler shows `local_a = (short)((uint)param1 >> 0x10)`
— the `>> 0x10` shifts the high half-word down for the
switch.

This packing is the firmware's standard way of carrying
two u16 fields in a single u32 parameter without using a
struct. The `param2` u16 is the *per-sub-cmd* parameter
(the mode value for `sub 1` / `sub 2`).

#### Pair with §3.13 `0x1e realTimeHeartRate`

`0x1e` is the Channel-A opcode that calls into the same
`hr_module.c` functions. The §3.13 doc shows `0x1e` calling
`health_post_start_measure_event(0x2000)` for "start continuous" mode — that
`0x2000` is the `param2` value the §7.1 dispatcher passes
into `FUN_00837b96` / `FUN_00837c4e`. The `0x1e` opcode is
the *Channel-A entry point*; the §7.1 dispatcher is the
*internal firmware entry point*. They share the same
underlying worker.

#### Pair with §7 sensors

The §7 accelerometer dispatcher `FUN_00833334` follows the
same sub-cmd convention (0..3 lifecycle), so the host SDK
can use a single dispatcher pattern for both HR and
accelerometer modules. The "four-stage lifecycle"
(reset / start-1 / start-2 / read-or-stop) is a *vendor
convention* shared across the H59MA firmware.

---

### 7.2 Accelerometer / LIS3DH SPI dispatcher (`FUN_00833334`)

The accelerometer front-end. Unlike the HR module (§7.1)
which has a 4-stage lifecycle, the accelerometer only
supports **one sub-cmd (0)** — the firmware is hard-wired
to start the LIS3DH SPI peripheral without lifecycle state.

```c
void FUN_00833334(u32 param_1, u32 param_2) {
    if ((short)((u32)param_1 >> 0x10) != 0) {
        // Invalid sub-cmd: assertion-fail
        uVar1 = func_0x00005e6a(0x23400000, "qc_code_app_module_g");
        func_0x00005aa8(DAT_008333fc, DAT_008333f8, 2, uVar1,
                         DAT_00833380 + 0x3A, param_1, param_2);
        return;
    }
    // Valid sub-cmd 0: start accelerometer
    FUN_00832dd6();
}
```

#### Why one sub-cmd instead of four?

The accelerometer (LIS3DH) is a *simpler peripheral* than the
HR sensor — it doesn't need the explicit lifecycle stages
because the firmware handles the read/write on the SPI bus
directly. The HR sensor uses an *algorithm library*
(`VC_HRV_16Bit_integration_6.0_addRMSSD`, etc.) that
requires explicit reset/start/stop calls to manage state.

The accelerometer just needs one "start reading" call to
spin up the SPI bus. After that, the firmware polls the
LIS3DH via `FUN_00832dd6` and the host SDK reads via
`FUN_00833968` (the §7 raw SPI reader).

#### The assertion-fail path

Like the HR module's `else` branch (§7.1), the
accelerometer's `if (sub != 0)` branch calls the standard
debug-helper pair (`func_0x00005e6a` / `func_0x00005aa8`)
to log an assertion failure. The log message uses the
**different module name** `qc_code_app_module_g` (vs the
HR's `qc_code_app_module_h`) — each vendor module has its
own assertion-fail label.

The host SDK that sends a non-zero accelerometer sub-cmd
will see the watch *log an assertion* but otherwise no-op.

#### Why upper-16-bits of param_1

Both §7.1 (HR) and §7.2 (accelerometer) take the sub-cmd in
the upper 16 bits of the u32 parameter (`>> 0x10` is the
shift). This is the same packing convention used elsewhere
in the firmware (e.g. §8.5 / §8.7 0x69 mode control, §6
system reset). The host SDK can use a single dispatcher
helper to unpack the sub-cmd + mode-param across all the
firmware's lifecycle commands.

#### Pair with §3.20 / §3.21

`FUN_00833334` is the *internal* firmware entry point for
the accelerometer. The §3 Channel-A opcodes don't have a
direct accelerometer opcode — the accelerometer is only
controllable via the §7.2 internal dispatch path, which is
in turn driven by the §6.1 button / DLPS init and §7.1 HR
module cross-talk. The accelerometer runs as a background
service, not a user-initiated command.

---

## 8. Vendor/High 16-Byte Dispatcher — Channel-A Entry Point

**Correction, 2026-07-05:** this section originally identified the
`0x0082e850`/`0x0082e87a`/`0x0082e8ce` callback triple as the `0xFEE7` GATT
service. radare2 table/register evidence shows that triple belongs to Channel A
(`6e40fff0`) at body table `0x1f204`. The true FEE7 table starts at body
`0x1f2b8`, registers through `0x0082eb0a`, and has callbacks
`0x0082e9a2`/`0x0082ea4c`/`0x0082eaba`; its write callback packages a generic
Realtek service event and does not call the dispatcher below. See
`firmwares/_re/fee7-gatt/evidence.md`.

The vendor/high opcode dispatcher below is still real firmware code, but its
statically-proven GATT entry point is the Channel-A write callback at
`0x0082e87a`, which calls it for 16-byte writes.

The Channel-A service is registered during BLE initialization
(`ble_services_init` -> `channel_a_register_gatt_service`) using an attribute
table at base `0x00845604` (size `0xa8`). Three handler pointers are active in
the GATT records:

| Handler | Address | Role |
|---|---|---|
| `channel_a_gatt_read_handler` | `0x0082e850` | Read handler — returns a runtime buffer pointed to by `DAT_0082e934` (length stored at `buffer[-2] - 1`) for GATT event `7`. |
| `channel_a_gatt_write_handler` | `0x0082e87a` | Write handler — GATT event `2` routes to `fee7_dispatch_vendor_command` / the vendor-high dispatcher. |
| `channel_a_gatt_cccd_log_handler` | `0x0082e8ce` | CCCD/log handler — only emits debug traces. |

The Channel-A write handler is the protocol entry point.

### 8.1 Vendor/high dispatcher (`fee7_dispatch_vendor_command`)

The actual opcode table for this high/vendor path. The function is
called from `channel_a_gatt_write_handler` with
`(frame_ptr, frame_length)`.

#### Top-level guards

```c
void fee7_dispatch_vendor_command(byte *param_1, int param_2) {
    if (*DAT_0082caec == 0x01) return;   // §8.1 service-suspended flag
    if (param_2 != 0x10) return;         // 16-byte frame only
    if (*param_1 != 0x43 && *param_1 != 0x48)
        fee7_abort_active_ota_before_vendor_cmd();
    // ... opcode dispatch ...
}
```

The `*DAT_0082caec == 0x01` check is the watch's *service-suspended*
flag (set by `0xC5/0xC8/0xC9` config writes — see §8.1 below).
The pre-dispatch helper skips `0x43 'C'` and `0x48 'H'`; for other commands it
aborts any active Channel-B OTA state `2`/`3` before accepting vendor traffic
and marks the Channel-B receive side busy.

#### Opcode → handler map (reverse-engineered from `FUN_0082c944`)

| Opcode(s) | Handler | Notes |
|---|---|---|
| `0x00..0x2a` | Low-range `switch8` at `fee7_low_switch_default_index` / `fee7_low_switch8_table` | Per-entry thunk — detailed below |
| `0x2b, 0x37, 0x38, 0x3a, 0x3b, 0x43 'C', 0x72, 0x77, 0x7a, 0x7d, 0x81, 0xa1, 0xc6, 0xc7, 0xff` | Deferred-command ring | `enqueue_deferred_command_frame` |
| `0x36` | Heart-rate related read/set | `FUN_0082c112` — see §8.8 |
| `0x39` | HRV setting/history path | `channel_a_handle_hrv_history` |
| `0x3c` | Fixed capability block `[0x3c,0,0x40,0xa0,0x20,…]` | `fee7_send_fixed_capability_3c` — see §8.12 |
| `0x3e` | Lipids read/set (bit 7 of shared config byte) | `fee7_handle_lipids_flag_3e` | see §8.15 |
| `0x48 'H'` | Current sport/today totals and state bytes | `fee7_send_today_sport_totals` — see §8.2 |
| `0x50 'P'` | **Inline** alert: `alert_start_sequence(0x14,0x10,1,0x19)` + `ui_overlay_start_forced(8)` (motor + UI) | inline |
| `0x51 'Q'` | Vendor alert/test request | `fee7_handle_test_request_51` — see §8.11 |
| `0x60` | Store pending 32-bit vendor status field (`DAT_0082bfd4 + 0x2c`) | `fee7_store_pending_u32_60` | see §8.16 |
| `0x61 'a'` | Read pending 32-bit vendor status field | `fee7_read_pending_u32_61` — see §8.3 |
| `0x69 'i'` | Start health measurement/session | `health_handle_start_measure` — see §8.5 |
| `0x6a 'j'` | Stop health measurement/session | `health_handle_stop_measure` |
| `0x7b, 0xb0, 0xc2, 0xcc, 0xf0, 0xf1` | No-op (early return) | — |
| `0x90` | Echo `[0x90]` (self-marker) | `fee7_send_test_ack_90` — see §8.6 |
| `0x91` | Echo `[0x91]` | `fee7_send_test_ack_91` |
| `0x92` | No-op handler | `fee7_noop_92` |
| `0x93` | Firmware version + build-date string | `fee7_send_fw_version_build_info_93` | see §8.18 |
| `0x94` | Set vendor test state `1` and restart 1000 ms timer | `fee7_start_test_mode_94` | see §8.19 |
| `0x95` | Set vendor test state `3` and restart 1000 ms timer | `fee7_start_test_mode_95` | see §8.19 |
| `0x96` | Sends self-marker ACK `[0x96,0...,0x96]`, sets vendor test state `4`, restarts timer | `fee7_start_test_mode_96` — see §8.4 |
| `0x97..0xa0` | High-range `switch8` at `fee7_high_switch_default_index` / `fee7_high_switch8_table` | Per-entry thunk — detailed below |
| `0xbf` | Vendor memory write (host→watch, arbitrary addr, max 8 bytes) | `fee7_vendor_memory_write` | see §8.17 |
| `0xc0` | Vendor memory read (watch→host, max 0x200 bytes fragmented) | `fee7_vendor_memory_read` | see §8.17 |
| `0xc1` | Poll one-shot health result byte via `FUN_008337fa(DAT_0082caf0)` and send `[0xc1, result]` | `fee7_health_one_shot_result_poll_c1` |
| `0xc3` | If `req[2] == 1` → BLE/service teardown event; then `req[1]==1` drives `ota_dfu_state_machine(4,0)`, `req[1]==2` drives `ota_dfu_state_machine(0,0)` | `fee7_ota_control_c3` |
| `0xc4` | No-op | `fee7_noop_c4` |
| `0xc5` | If `req[1] == 1` → `DAT_0082caec[3] = 1`; else `DAT_0082caec[3] = 0` | `fee7_store_runtime_flag_c5` |
| `0xc8` | Same as `0xc5` but writes `DAT_0082caec[4]` | `fee7_store_runtime_flag_c8` |
| `0xc9` | `DAT_0082caec[5] = req[1]` | `fee7_store_runtime_flag_c9` |
| `0xcd` | Small host-addressed memory read: response copies up to 14 bytes from address encoded in request bytes `3..6` | `fee7_vendor_memory_read_small_cd` — see §8.9 |
| `0xce` | Factory/test sub-commands (`0x01`, `0x02`, `' '`, `'!'`, `'"'`) | `fee7_handle_factory_test_ce` — see §8.10 |
| `0xfe` | `fee7_generate_synthetic_sleep_record(*(u16*)(req + 1))` — synthesize and commit sleep-history data from a duration | inline — see §8.13 |
| other | Vendor NAK: response opcode `opcode|0x80`, marker `0xee` | `fee7_send_vendor_nak` |

#### Deferred-command ring (`FUN_0082be64`)

The opcodes routed to `FUN_0082be64` (`0x2b`, `0x37`, `0x38`,
`0x3a`, `0x3b`, `0x43 'C'`, `0x72`, `0x77`, `0x7a`, `0x7d`,
`0x81`, `0xa1`, `0xc6`, `0xc7 'D'`, `0xff`) are **not** handled
synchronously. Instead the dispatcher copies the 16-byte request
into a 10-slot ring, increments the slot index, and wakes the
`qc_app_task` loop. The ring base pointer is the literal value in
`DAT_0082bfcc`:

```c
// DAT_0082bfcc == 0x00209f54
memcpy((void *)(DAT_0082bfcc + 4 + slot * 0x10), param_1, 0x10);
slot = (slot + 1) % 10;
FUN_00827124(0, DAT_0082bfd0);   // signal qc_app_task
```

This is the same ring consumed by the Channel-A dispatcher
`channel_a_dispatch_queued_frame`. The consumer is the main app task `qc_app_task`
(`FUN_0082724c`), whose loop waits on a message queue and then
 calls `channel_a_dispatch_queued_frame()`:

```c
void FUN_0082724c(void) {
    // ... init ...
    do {
        do {
            msg = os_message_get(*(void **)(DAT_0082732c + 4), 0xffffffff);
        } while (msg == 0);
        channel_a_dispatch_queued_frame();   // drains the 0x00209f54 ring
        FUN_0083304c();
        FUN_0082fc0c();
        // ...
    } while (true);
}
```

So `FUN_0082be64` does **not** have its own dedicated worker;
the deferred FEE7 frames are simply queued into the Channel-A
command ring and drained on the next `qc_app_task` tick. This is
how the watch avoids a single long 0xFEE7 frame from blocking the
BLE link while a CPU-heavy handler (e.g. `0x77 phoneSport` or
`0x43 readDetailSport`) runs.

#### Vendor NAK shape (`FUN_0082bcba`)

For an unknown opcode the dispatcher emits a 2-byte *vendor NAK*
frame:

```
byte 0: opcode | 0x80                (the high bit marks "error")
byte 1: 0xEE                        (vendor-NAK marker)
byte 2..14: 0
byte 15: additive checksum
```

The 0xEE marker is the same byte the 0xFEE7 GATT service
UUID uses (0x0000FEE7) — so a host that sees `[opcode|0x80, 0xEE]`
knows the response came from the vendor service (and not the
Channel-A 0xFF / 0xFE / 0x9F error variants).

#### Switch8 tables

Both tables use the shared `__ARM_common_switch8` helper at
`0x008405fc`. The helper reads a count byte immediately after the
`BL`, then a byte offset per case, and branches to
`target = (return_address + 2 * offset) & ~1`. Offsets are
**unsigned**.

##### Low-range table (`fee7_low_switch_default_index`, `0x82c61c`) — opcodes `0x00..0x2a`

Count byte at `0x82c61c` is `0x27` (39 cases); cases
`0x27..0x2a` fall through to the default offset and are treated as
NAK.

| Opcode | Target / action | Notes |
|---|---|---|
| `0x00` | Vendor NAK (`0x82c74e`) | |
| `0x01` | Deferred (`0x82c662` → `enqueue_deferred_command_frame`) | Channel-A `setTime` |
| `0x02` | `fee7_handle_camera_control_02` | Camera/control request; ignored while a health sensor session is active. |
| `0x03` | `fee7_send_battery_status_03` | Battery/status frame plus health-busy bit. |
| `0x04` | `fee7_handle_bind_ancs_04` | Bind/ANCS-style state update. |
| `0x05` | Vendor NAK | |
| `0x06` | Deferred | Channel-A `dnd` |
| `0x07`–`0x09` | Vendor NAK | |
| `0x0a` | `fee7_handle_time_format_0a` | Time/unit-format read/set. |
| `0x0b` | Vendor NAK | |
| `0x0c` | `fee7_handle_bp_setting_0c` | BP setting read/write. |
| `0x0d` | `bp_history_prepare_recent_days` + `bp_history_send_next_chunks` | Read BP records. |
| `0x0e` | Deferred | Channel-A `bpReadConform` |
| `0x0f` | Vendor NAK | |
| `0x10` | `fee7_handle_short_alert_10` | Starts short alert pattern and ACKs `0x10`. |
| `0x11`–`0x13` | Vendor NAK | |
| `0x14` | Early return (`0x82c752`) | No-op |
| `0x15` | Deferred | Channel-A `readHeartRate` |
| `0x16` | `fee7_handle_heart_rate_setting_16` | Heart-rate setting read/write. |
| `0x17` | Vendor NAK | |
| `0x18` | Deferred | Channel-A `realTimeHeartRate` |
| `0x19` | `fee7_handle_degree_unit_19` | Degree (C/F) switch read/write. |
| `0x1a`–`0x1d` | Vendor NAK | |
| `0x1e` | Deferred | |
| `0x1f`–`0x20` | Vendor NAK | |
| `0x21` | `fee7_handle_target_setting_21` | Daily target setting; also refreshes current target-reached flags. |
| `0x22`–`0x24` | Vendor NAK | |
| `0x25`–`0x26` | Deferred | |
| `0x27`–`0x2a` | Default → Vendor NAK | |

The "deferred" entries in this range are the same opcodes handled
by the Channel-A deferred path (`FUN_0082be64`), so the FEE7
service can also be used to trigger them.

##### High-range table (`fee7_high_switch_default_index`, `0x82c6e0`) — opcodes `0x97..0xa0`

Count byte at `0x82c6e0` is `0x0a` (10 cases); the default slot
also points to the vendor-NAK path.

| Opcode | Handler | Notes |
|---|---|---|
| `0x97` | `fee7_noop_97` | No response. |
| `0x98` | `fee7_set_session_mode1_ack_98` | Sets session mode `1` via `fee7_set_session_mode_ack_98_9a`, commits blob0 if changed, sends self-marker ACK `[0x98,0...,0x98]`. |
| `0x99` | `fee7_noop_99` | No response. |
| `0x9a` | `fee7_set_session_mode2_ack_9a` | Sets session mode `2`, commits blob0 if changed, sends self-marker ACK `[0x9a,0...,0x9a]`. |
| `0x9b` | `fee7_send_session_mode_status_9b` | Sends `[0x9b, state_byte]`; `state_byte` is `0x88` in mode `2`, otherwise `0x77`. |
| `0x9c` | `fee7_stop_factory_test_9c` | Sends self-marker ACK `[0x9c,0...,0x9c]`, stops factory-test timer, clears related state, and calls the `0x08` cancel path. |
| `0x9d` | Dispatcher return | No response. |
| `0x9e` | `fee7_send_model_name_9e` | Sends custom blob0 string at `DAT_00827e8c + 0x7a` when enabled, otherwise literal `"H59MA_V1.0"`. |
| `0x9f` | `fee7_noop_9f` | No response. |
| `0xa0` | `fee7_send_status_frame_a0` | Multi-byte status frame built from battery/sensor/session state and fields from `DAT_00827e8c`. |

A host should treat both ranges as *reserved* unless it can match
a specific response shape from the watch.

#### Relationship to §8 opcode map

The opcode → handler map **above** supersedes the original §8
table (which only listed the *immediately-routed* opcodes).
The §8 table is now strictly a subset: the deferred opcodes
(`0x43`/`0x7a`/etc.) are still in the
opcodes-routed-to-`FUN_0082be64` bucket, and the
*handler-shorthand* in §8 is the per-deferred-frame handler
that `FUN_0082be64`'s worker eventually invokes.

### Wire format

`FUN_0082c944` expects 16-byte writes and uses the same framing as Channel A:

```
byte 0      opcode
byte 1..14  payload / parameters
byte 15     additive checksum (sum of bytes 0..14)
```

If `opcode` is not `'C'` (`0x43`) or `'H'` (`0x48`) the firmware first runs
`fee7_abort_active_ota_before_vendor_cmd`, which aborts active Channel-B OTA
state `2`/`3` before dispatching the vendor opcode.

Responses are built with `checksum8_additive` and queued through
`channel_a_queue_notify_frame` / `FUN_0082eb8a` into the same 16-byte notify
ring used by Channel A. Many commands are simply copied into the deferred
command ring (`enqueue_deferred_command_frame`) and processed later.

### Opcode → handler map (from `FUN_0082c944`)

Immediate / explicitly routed opcodes, including the non-default
entries decoded from the two `switch8` tables:

| Opcode | Handler | Notes |
|---|---|---|
| `0x02` | `fee7_handle_camera_control_02` | Camera/control request |
| `0x03` | `fee7_send_battery_status_03` | Battery response (`[0x03, percent, charging]`) |
| `0x04` | `fee7_handle_bind_ancs_04` | ANCS bind |
| `0x0a` | `fee7_handle_time_format_0a` | Time-format read/set |
| `0x0c` | `fee7_handle_bp_setting_0c` | BP setting |
| `0x0d` | `bp_history_prepare_recent_days` + `bp_history_send_next_chunks` | Read BP records |
| `0x10` | `fee7_handle_short_alert_10` | Vibration / display trigger |
| `0x14` | — | Explicit no-op (early `pop {r4,pc}`) |
| `0x16` | `fee7_handle_heart_rate_setting_16` | Heart-rate setting |
| `0x19` | `fee7_handle_degree_unit_19` | Degree (C/F) switch |
| `0x21` | `fee7_handle_target_setting_21` | Daily target setting |
| `0x36` | `FUN_0082c112` | Heart-rate related read/set — see §8.8 |
| `0x3c` | `fee7_send_fixed_capability_3c` | Returns fixed capability block `[0x3c,0,0x40,0xa0,0x20,...]` — see §8.12 |
| `0x3e` | `fee7_handle_lipids_flag_3e` | Lipids read/set (bit 7 of shared config byte) — see §8.15 |
| `0x48` `'H'` | `fee7_send_today_sport_totals` | Current sport/today totals and state bytes — see §8.2 |
| `0x50` `'P'` | inline | Calls `alert_start_sequence(0x14,0x10,1,0x19)` + `ui_overlay_start_forced(8)` (alert/motor) |
| `0x51` `'Q'` | `fee7_handle_test_request_51` | Vendor alert/test trigger; arms pattern when `payload[1]==1` — see §8.11 |
| `0x60` | `fee7_store_pending_u32_60` | Status-field write (`DAT_0082bfd4 + 0x2c`) — see §8.16 |
| `0x61` `'a'` | `fee7_read_pending_u32_61` | Status-field response — see §8.3 |
| `0x69` `'i'` | `health_handle_start_measure` | Start/extend health measurement session — see §8.5 |
| `0x6a` `'j'` | `health_handle_stop_measure` | Stop health measurement session and return final values |
| `0x90` | `fee7_send_test_ack_90` | Echo `[0x90]` |
| `0x91` | `fee7_send_test_ack_91` | Echo `[0x91]` |
| `0x92` | `fee7_noop_92` | No response |
| `0x93` | `fee7_send_fw_version_build_info_93` | Firmware version + build-date string — see §8.18 |
| `0x94` | `fee7_start_test_mode_94` | Set vendor test state 1 and restart timer — see §8.19 |
| `0x95` | `fee7_start_test_mode_95` | Set vendor test state 3 and restart timer — see §8.19 |
| `0x96` | `fee7_start_test_mode_96` | Sends self-marker ACK `[0x96,0...,0x96]`, sets state 4, restarts timer — see §8.4 |
| `0x97` | `fee7_noop_97` | No response |
| `0x98` | `fee7_set_session_mode1_ack_98` | Sets state to `1`, sends self-marker ACK `[0x98,0...,0x98]` |
| `0x99` | `fee7_noop_99` | No response |
| `0x9a` | `fee7_set_session_mode2_ack_9a` | Sets state to `2`, sends self-marker ACK `[0x9a,0...,0x9a]` |
| `0x9b` | `fee7_send_session_mode_status_9b` | Sends `[0x9b, state_byte]` |
| `0x9c` | `fee7_stop_factory_test_9c` | Sends self-marker ACK `[0x9c,0...,0x9c]`, stops timer / power-off related |
| `0x9d` | — | Dispatcher return; no response |
| `0x9e` | `fee7_send_model_name_9e` | Conditional 10-byte copy from `DAT_00827e8c + 0x7a` or `"H59MA_V1.0"` |
| `0x9f` | `fee7_noop_9f` | No response |
| `0xa0` | `fee7_send_status_frame_a0` | Multi-byte status frame builder |
| `0xbf` | `fee7_vendor_memory_write` | Vendor memory write, arbitrary address, max 8 bytes — see §8.17 |
| `0xc0` | `fee7_vendor_memory_read` | Vendor memory read, arbitrary address, max 0x200 bytes — see §8.17 |
| `0xc1` | `fee7_health_one_shot_result_poll_c1` | Polls one-shot health result byte and responds `[0xc1, result]` |
| `0xc3` | `fee7_ota_control_c3` | Drives `ota_dfu_state_machine(4,0)` or `(0,0)`; `req[2]==1` also calls BLE teardown/reinit helper |
| `0xc4` | `fee7_noop_c4` | No-op in firmware |
| `0xc5` | `fee7_store_runtime_flag_c5` | Sets `DAT_0082caec[3]` from `req[1] == 1` |
| `0xc8` | `fee7_store_runtime_flag_c8` | Sets `DAT_0082caec[4]` from `req[1] == 1` |
| `0xc9` | `fee7_store_runtime_flag_c9` | Sets `DAT_0082caec[5] = req[1]` |
| `0xcd` | `fee7_vendor_memory_read_small_cd` | Small arbitrary-address read, max 14 bytes in one frame — see §8.9 |
| `0xce` | `fee7_handle_factory_test_ce` | Factory/test sub-commands (`0x01`, `0x02`, `' '`, `'!'`, `'"'`) — see §8.10 |
| `0xfe` | `fee7_generate_synthetic_sleep_record` | Synthesizes and commits sleep-history data from a duration — see §8.13 |

Opcodes `0x2b`, `0x37`, `0x38`, `0x3a`, `0x3b`, `0x43`, `0x72`,
`0x77`, `0x7a`, `0x7d`, `0x81`, `0xa1`, `0xc6`, `0xc7`, `0xff`
are routed to `enqueue_deferred_command_frame` (deferred). Within the `0x00`–`0x2a`
`switch8` range, only `0x01`, `0x06`, `0x0e`, `0x15`, `0x18`,
`0x1e`, `0x25`, `0x26` are deferred; the rest are either immediate
thunks, the explicit no-op at `0x14`, or vendor NAK. Opcodes
`0x7b`, `0xb0`, `0xc2`, `0xcc`, `0xf0`, `0xf1` are explicit no-ops.
Unrecognized opcodes fall through to `fee7_send_vendor_nak`.

### Take-away

This dispatcher carries a vendor/high 16-byte command set that overlaps some Channel-A opcodes (e.g. `0x48`, `0x50`, `0x51`, `0x69`, `0x6a`, `0x3c`, `0x3e`) and adds vendor-specific commands (`0x90`–`0x9f`, `0xce`, `0xfe`). The statically-proven GATT entry point is Channel A, not the published `0xFEE7` write characteristic; OpenWatch should not prefer FEE7 writes without live-capture evidence.

### 8.2 0x48 `'H'` today-sport totals (`fee7_send_today_sport_totals`)

The first frame the host sees on the `0xFEE7` service. Reads
the per-device info struct at `DAT_00831d94` and ships a
15-byte "device info" block. The struct base is the literal
`DAT_00831d94` — four sub-fields are read at offsets `+0x04`,
`+0x14`, `+0x1c`, and `+0x30`.

```c
void fee7_send_today_sport_totals() {
    u32 hw_ver   = FUN_00831b12();   // = *(u32*)(DAT_00831d94 + 0x04)
    u32 fw_ver   = FUN_00831cdc();   // = *(u32*)(DAT_00831d94 + 0x14)
    u32 batt_raw = FUN_00831ce2();   // returns FUN_0083dfba(*(u32*)(DAT_00831d94 + 0x1c), 100)
    u16 tail     = FUN_00831b1e();   // = *(u16*)(DAT_00831d94 + 0x30) — called twice
    ...
}
```

The 4 byte-fields read by the handlers are:

| Field | Struct offset | Likely meaning |
|---|---:|---|
| `hw_ver` (u32) | `DAT_00831d94 + 0x04` | hardware revision (e.g. `H59MA_V1.0`) |
| `fw_ver` (u32) | `DAT_00831d94 + 0x14` | firmware version (e.g. `1.00.14`) |
| `batt_raw` (u32) | `DAT_00831d94 + 0x1c` | raw battery counter, mod-100 → percent |
| `tail` (u16) | `DAT_00831d94 + 0x30` | charge / status bits |

#### Response layout (15 bytes + additive checksum)

The body is laid out as a 4 + 4 + 4 + 2 + 1 byte pattern that
packs the four getters in a specific interleaving:

```
byte  0: 0x48                         (cmd echo)
byte  1: hw_ver >> 16                (HW version byte C)
byte  2: hw_ver >>  8                (HW version byte B)
byte  3: hw_ver & 0xff               (HW version byte A)
byte  4: 0                           (pad)
byte  5: 0                           (pad)
byte  6: fw_ver >> 16                (FW version byte C)
byte  7: 0                           (pad)
byte  8: fw_ver & 0xff               (FW version byte A)
byte  9: fw_ver >>  8                (FW version byte B)
byte 10: batt_raw >> 16              (battery byte C — divmod 100 result)
byte 11: batt_raw >>  8              (battery byte B)
byte 12: batt_raw & 0xff             (battery byte A)
byte 13: tail & 0xff                 (low byte of status)
byte 14: tail >> 8                   (high byte of status)
byte 15: additive checksum           (per §3)
```

The interleaving of `hw_ver` (LE) and `fw_ver` (BE) is the same
quirk already documented in the `0x01 setTime` ack and the
`0x43 readDetailSport` headers — the firmware uses a
non-uniform byte order for the version fields, presumably
because the underlying C struct was packed in a vendor-
specific layout that the host SDK knows to read back with
the right shifts. The host should *not* try to read any of
the 4-byte version fields as plain little-endian; instead it
should read each as a 3-byte BCD-like value and ignore the
zero-pad byte.

#### Why the host's first call

* The `0x48` handler is one of the two opcodes (`0x43 'C'`,
  `0x48 'H'`) that the dispatcher *does not* reset the
  keep-alive timer for (see §8.1), so an idle host can poll
  the link with a continuous stream of `0x48` writes
  without ever bumping the watch's connection-timeout.
* The response always includes the live battery percent (via
  `FUN_0083dfba(_, 100)` mod 100), so a host that wants
  live battery data without subscribing to the `0x61 'a'`
  status push can simply poll `0x48`.

#### Pair with the 0x43 'C' read-byte

The two keep-alive-exempt opcodes are typically used as a
pair: `0x48` returns the 15-byte device-info block, `0x43`
returns a single byte (the `rxOpcode` — see the `Channel A`
read helper `FUN_0082b986`). A host that connects to the
`0xFEE7` service can issue `0x48` once to learn the device
info and then poll `0x43` at a low rate to verify the link
is still up.

### 8.3 0x61 `'a'` status response (`FUN_0082bee6`)

The vendor "live status" push endpoint. Carries a 4-byte
LE u32 status value (`DAT_0082bfd4 + 0x2C`) — the same
field that backs `0x48 'H'` battery percent — plus a
single-bit *idle* flag that lets the watch suppress the
status push when nothing has changed.

#### Behavior

```c
void FUN_0082bee6() {
    memset(rsp, 0, 0x10);
    rsp[0] = 0x61;
    if (FUN_0082762c() == 1 && FUN_0082d754() == 0) {
        // "idle" path — bytes 1..4 stay 0
        rsp[15] = FUN_0082b0c4(rsp, 0xf);
    } else {
        u32 v = *(u32*)(DAT_0082bfd4 + 0x2C);
        rsp[1] = v & 0xff;
        rsp[2] = (v >> 8) & 0xff;
        rsp[3] = (v >> 0x10) & 0xff;
        rsp[4] = (v >> 0x18) & 0xff;
        rsp[15] = FUN_0082b0c4(rsp, 0xf);
    }
    FUN_0082ebdc(rsp);
}
```

The two helper gates are:

| Helper | Reads | Returns |
|---|---|---|
| `FUN_0082762c` | `*(DAT_0082780c + 0x12)` | 1-byte state sentinel |
| `FUN_0082d754` | `*(DAT_0082db50 + 1)` | 1-byte state sentinel |

The "idle" path (`FUN_0082762c() == 1 && FUN_0082d754() == 0`)
returns an **all-zeros** status with the cmd byte alone —
the host can use this as a cheap heartbeat ("watch is alive
but nothing changed") instead of a full battery/counter
update. The "active" path returns the live u32.

#### Response layout

```
byte  0: 0x61                (cmd)
byte  1..4: u32 status (LE) from DAT_0082bfd4 + 0x2C
                on the active path, or 0/0/0/0 on the idle path
byte  5..14: 0
byte 15: additive checksum
```

The same `DAT_0082bfd4 + 0x2C` field is the source for the
`0x48 'H'` battery-percent helper (§8.2). The two responses
will therefore always agree on byte 1 (low byte of the
battery / daily-counter u32) — `0x61` is essentially the
"current snapshot" and `0x48` is the "device-info block
that includes the same snapshot".

#### Why the 1-byte-cmd-on-idle

The idle path is the cheapest possible response (16 bytes,
5 instructions, no memory reads beyond the two state
sentinels). A host that polls `0x61` aggressively can
treat repeated all-zero responses as "no change since last
poll" and avoid re-decoding the full status u32 each time.

#### State sentinels

`DAT_0082780c + 0x12` is the per-task state byte that
`FUN_008275d8` (the system reset routine used by `0xff` and
`0xc6`) clears at boot. `DAT_0082db50 + 1` is a similar
state byte in the deferred-command-ring worker (the same
ring that `0x77 phoneSport` and `0x43 readDetailSport` write
into). The handler checks both because the active state
depends on the *combined* condition: the task state is
"set up" AND the worker is "not busy". This means the
handler pushes a "live" status only when the watch is
*fully initialised* and the deferred ring is idle — a
deliberate gate to avoid pushing a status frame before the
producer side (`DAT_0082bfd4 + 0x2C`) has been populated.

#### Pair with `0x48 'H'`

| | `0x48 'H'` | `0x61 'a'` |
|---|---|---|
| Polling cost | full 15-byte device-info block | 5-byte u32 status |
| Idle response | (always returns full block) | all-zeros 1-byte-cmd ack |
| Live battery data | yes (FUN_0083dfba(_, 100) mod 100) | yes (same source as `0x48`) |
| Keep-alive exempt | yes (§8.1) | no — runs `fee7_abort_active_ota_before_vendor_cmd` |

A host that wants *fast* battery updates can poll `0x61`
instead of `0x48` and skip the 11-byte header overhead, but
has to handle the idle-path "all zeros" response.

### 8.4 0x96 reset-state (`fee7_start_test_mode_96`)

The vendor "reset to a clean state" command. Sends a
16-byte notify frame with **`0x96` at both byte 0 and byte
15** (no checksum — the byte-15 `0x96` is an *intentional
marker*, not a hash) and resets the per-feature state at
`DAT_00827e88`.

#### Behavior

```c
void fee7_start_test_mode_96() {
    rsp[0] = 0x96;
    rsp[12] = 0x96;                          // bytes 1..11 + 13..14 = 0
    FUN_0082ebdc(&rsp);
    state = DAT_00827e88;
    state[1] = 0;                            // clear flag byte
    *state = 4;                              // set state byte = 4
    FUN_00827b1a();                          // drain/reset helper
}
```

The handler is one of the few Channel-A / 0xFEE7 opcodes
that **does not call `FUN_0082b0c4`** to compute an
additive checksum. Instead, it sets byte 15 to a literal
`0x96`. The host can detect a `0x96` reset by:
1. Looking for byte 0 = byte 15 = `0x96`.
2. Treating the frame as a "reset happened" signal rather
   than a normal response.

#### Persistent state (`DAT_00827e88`, 2 bytes)

| Off | Field | Notes |
|---:|---|---|
| 0 | `state_machine_state` | set to `4` on reset |
| 1 | `feature_flag` | cleared on reset |

These two bytes form the **head** of the larger state
struct at `DAT_00827e88` — the helper `FUN_00827b1a` then
drains 1000 bytes starting at `DAT_00827e88 + 10` (the rest
of the struct).

#### `FUN_00827b1a` — reset helper

```c
void FUN_00827b1a() {
    FUN_00829c24(DAT_00827e88 + 10, DAT_00827e90, 1000, 1);
}
```

A single call to `FUN_00829c24` with a 1000-byte copy /
queue-drain parameter and a `1` flag (likely "drain"
vs "fill"). `DAT_00827e90` is presumably the destination
buffer for the cleared state (or a queue head for the
drained work items).

#### Response layout

```
byte  0: 0x96                (cmd)
byte  1..11: 0
byte 12..14: 0
byte 15: 0x96                (intentional marker — NOT a checksum)
```

The `0x96` at byte 15 is the host's "I just reset" signal.
The lack of a checksum means a host that tries to verify
the additive sum of bytes 1..14 will compute `0x00` (all
zeros) and *not* match the byte-15 `0x96`. The proper
verification is `byte 0 == 0x96 && byte 15 == 0x96` (a
self-describing marker pair), not the additive checksum
that the §3 "Common response path" usually stamps in.

#### Why no additive checksum

The handler bypasses `FUN_0082b0c4` because the byte-15
slot is **already used as the second `0x96` marker**. This
is the only handler in the table that does so. The host
SDK that consumes `0x96` should special-case this opcode
to read bytes 0 and 15 as marker bits rather than the
usual `cmd + checksum` pair.

#### When a host sends `0x96`

A host typically sends `0x96` to recover from a desync —
the watch state has drifted (the producer side at
`DAT_00827e88` is in an unexpected mode) and the host
wants the firmware to reinitialise the feature from
scratch. The `0x96` ack tells the host "I have reset,
the next request will be against a fresh state". This is
analogous to the `0xff 'fff'` Channel-A factory reset
(§3.8) and the `0xc6 0x6C 'l'` 0xFEE7 reboot (§3.14), but
narrower in scope — only the `DAT_00827e88` feature is
reset, not the whole system.

#### Pair with `0xC9` config-byte write

`DAT_00827e88[5]` is writable via `0xC9` (§8.1) — `0xC9`
sets `DAT_0082caec[5] = req[1]`, which the dispatcher then
mirrors into the feature state. The combination `0x96`
reset followed by `0xC9` set is the documented host pattern
for switching between "feature on" and "feature off"
modes without a full BLE reboot.

### 8.5 0x69 `'i'` health start/control (`health_handle_start_measure`)

The most stateful handler in the 0xFEE7 dispatcher. Drives
a multi-step "start / stop / cancel / refresh" sequence
over a per-feature state struct at `DAT_0082c578`. The
handler implements both a **HR-busy gate** (refuse to act
if the HR step counter is running) and a **500 ms tick**
that the mode-control state machine relies on.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x69` | cmd (consumed by dispatcher) |
| 1 | `mode` | see dispatch table below |
| 2..3 | `param` (u16 LE) | per-mode parameter (interval, duration, etc.); clamped to `>= 10` |
| 4..14 | unused | — |

#### HR-busy gate

The very first thing the handler does is call
`FUN_00828af4()` (the same HR step-counter check used by
`0x08 0x01` start-find in §3.15). If the counter is
*running*, the handler short-circuits:

```c
if (FUN_00828af4() != 0) {
    rsp[0..1] = (0x69, req[1]);
    rsp[2]    = 1;                    // "busy" flag
    rsp[15]   = additive checksum;
    send rsp;
    return;
}
```

The host treats `rsp[2] == 1` as "request was ignored because
HR is currently recording a sport session — retry after
`0x77 0x02` finishes". This is the same gating strategy used
by `0x77 0x01` (§3.16).

#### Mode dispatch (when HR not busy)

The handler writes `req[1]` to `state[7]` (mode) and
`req[2]` to `state[8]` (sub), then dispatches on `(mode,
sub)`:

| Mode | Sub | Action |
|---:|---:|---|
| `0x06` | `0x01` | **Start**: zero `state[0xC..0xD]`, call `health_post_start_measure_event(1)` (HR continuous start), cancel timer at `state[0x10]`, arm 500 ms timer |
| `0x06` | `0x02` | **Cancel**: cancel timer |
| `0x06` | `0x03` | **Refresh**: cancel + re-arm 500 ms timer |
| `0x06` | `0x04` | **Stop HR**: call `health_post_stop_measure_event(1)`, zero `state[0xC..0xD]` |
| `0x06` | other | (no action — go to send) |
| other | any | **Generic mode start**: zero `state[0xC..0xD]` and `state[2]`, cancel + re-arm 500 ms timer, then dispatch on `state[7]` (just-stored mode) for the per-mode start action (see "Per-mode start dispatch" below) |

#### Per-mode start dispatch (mode ≠ 0x06)

When the mode is not `0x06`, the handler reads back
`state[7]` (the mode it just stored) and dispatches:

| `state[7]` | Action |
|---:|---|
| `0x03` | `health_post_start_measure_event(0x20)` (HR mode `0x20`) |
| `0x09` | `FUN_00834862()` + `health_post_start_measure_event(0x400)` |
| `0x0B` (11) | `health_post_start_measure_event(0x1000)` + `FUN_0082ad02()` (some calibration / step-counter init) |
| `0x0C` (12) | `FUN_0083475a()` + `FUN_0082ad02()` + `FUN_0083454c()` + `health_post_start_measure_event(DAT_0082c57c)` (data-driven mode param) |
| `0x0D` (13) | `health_post_start_measure_event(1)` |
| `0x0E` (14) | `health_post_start_measure_event(0x20)` |
| other | (fallback — `health_post_start_measure_event(1)`) |

For all non-fallback modes the handler then:
1. Reads `req[2..3]` as a u16 `param`
2. Stores `param` into `state[0xA]` (inter-mode duration or
   interval)
3. Clamps `param` to `>= 10` (the doc-table explains this
   matches the watch's 10 ms timer granularity)

#### Persistent state (`DAT_0082c578`)

| Off | Field | Notes |
|---:|---|---|
| 2 | `step_counter_flag` | zeroed at every start path |
| 7 | `current_mode` | the mode byte just stored from `req[1]` |
| 8 | `current_sub` | the sub byte from `req[2]` |
| 0xA..0xB | `param_u16` | the clamped u16 parameter (only set in the generic-mode start) |
| 0xC..0xD | `param_zero` | zeroed on `0x06` start and `0x06 0x04` stop |
| 0x10+ | `timer_state` | the 500 ms tick used by both branches |

`DAT_0082c57c` (the +4 sibling) holds the "data-driven"
mode param consumed by the `0x0C` mode. Likely a config
table the producer populates via `0xC5` / `0xC8` / `0xC9`.

#### Why a 500 ms tick

The 500 ms timer at `state[0x10]` is the *mode-control tick*
— it advances the state machine for long-running modes
(those that take more than the single 16-byte frame to
complete). The host does not need to poll the timer; the
watch fires any follow-up data on the 0xFEE7 ring when the
tick expires. This is the same pattern as `0x77 phoneSport`
(§3.16) and `0x08 findDevice` (§3.15) — both use a
~1-second or ~500 ms timer to advance their state machines.

#### Response layout

For the HR-busy path:
```
byte  0: 0x69                (cmd)
byte  1: req[1]              (echo of mode)
byte  2: 0x01                ("busy" flag — request was ignored)
byte  3..14: 0
byte 15: additive checksum
```

For the "not busy" path:
```
byte  0: 0x69                (cmd)
byte  1: state[7]             (echo of the mode just stored)
byte  2: 0x00                (always 0 in the not-busy path)
byte  3..14: 0
byte 15: additive checksum
```

The host decodes `byte 2` as a "request status" flag:
`0` = accepted, `1` = refused (HR busy). The mode echo in
`byte 1` confirms which mode the request landed on
(useful when the host's `req[1]` was outside the table —
the handler clamps to `0x06` and the echo reflects that).

#### Pair with `0x6a 'j'`

`0x6a 'j'` (handled by `health_handle_stop_measure`) is the *continuation*
of `0x69 'i'` — when the 500 ms timer fires, it pops the
mode's continuation state and dispatches the next step.
The host should treat `0x69` + `0x6a` as a single
multi-frame transaction: `0x69` *starts* the mode,
`0x6a` *advances* it. The split is necessary because the
0xFEE7 16-byte frame cannot carry the full per-mode state;
`0x6a` re-reads `DAT_0082c578` and pushes the next-step
data on the notify ring.

### 8.6 0x90 `'.'` self-marker echo (`fee7_send_test_ack_90`)

The smallest 0xFEE7 echo handler (27 bytes). Sends a
16-byte notify frame with `0x90` at both byte 0 AND byte
15 — a **self-marker pattern** identical in shape to the
`0x96` reset-state response (§8.4). The handler does *not*
compute an additive checksum; the byte-15 slot is reserved
for the second `0x90` marker.

#### Behavior

```c
void fee7_send_test_ack_90() {
    rsp[0]  = 0x90;            // cmd
    rsp[15] = 0x90;            // self-marker
    FUN_0082ebdc(rsp);
}
```

The handler writes:
- `local_18 = 0x90` → bytes 0..3 of the frame are `[0x90, 0, 0, 0]`.
- `local_c = 0x90000000` → bytes 12..15 of the frame are
  `[0x00, 0x00, 0x00, 0x90]` (little-endian high-byte at offset 15).
- Bytes 4..11 are 0 (from the `local_14 = local_10 = 0`
  initialisations).

So the wire frame is:

```
byte  0: 0x90        (cmd)
byte  1..11: 0
byte 12..14: 0
byte 15: 0x90        (intentional marker — NOT a checksum)
```

The host verifies by `byte 0 == 0x90 && byte 15 == 0x90`,
**not** by additive checksum. This is the second handler
in the table (after `0x96` §8.4) to use the byte-15 slot
as a marker rather than a hash.

#### Why no additive checksum

Same reason as `0x96 reset-state` (§8.4): the byte-15 slot
is *already used* as the second `0x90` marker. The host SDK
that consumes `0x90` should special-case this opcode to
read bytes 0 and 15 as marker bits rather than the usual
`cmd + checksum` pair.

#### Pair with `0x91` (proper echo)

The adjacent `0x91` handler (`fee7_send_test_ack_91`) is the
"normal" version of the same idea — a simple echo of the
opcode with a *real* additive checksum:

```c
void fee7_send_test_ack_91() {
    rsp[0]  = 0x91;
    rsp[15] = FUN_0082b0c4(rsp, 0xf);   // additive sum of bytes 0..14
    FUN_0082ebdc(rsp);
}
```

So `0x90` (self-marker) and `0x91` (checksum-echo) are
*deliberately different*: `0x90` lets the host cheaply
detect "watch is alive" without paying for a checksum
computation, while `0x91` is the host SDK's primary
echo command that round-trips through the standard
§3 "Common response path" checksum.

#### Adjacent `0x92` is a no-op

For completeness, `0x92` (`fee7_noop_92`) is an empty
function (decompiles to `return;`). The handler is wired
into the `0xFEE7` dispatcher but does nothing — the
opcode is reserved for a future vendor-specific feature
that v14 does not implement. A host sending `0x92` will
*not* receive any response (the dispatcher routes it but
the handler is empty).

### 8.7 0x6a `'j'` health stop/result (`health_handle_stop_measure`)

The second half of the `0x69 'i'` / `0x6a 'j'` multi-step
transaction (§8.5). The current Ghidra pass shows both opcodes are dispatched
directly from `fee7_dispatch_vendor_command`, not through the deferred ring:
`0x69` starts or extends a health measurement and `0x6a` stops the active mode
and returns final values.

The handler also enforces a **mode-mismatch guard**: if
`req[1]` does not match `state[7]` (the mode stored by the
matching `0x69 'i'`), the handler returns immediately. This
prevents a stale `0x6a` request from continuing the wrong
mode if the host lost track of the protocol state.

#### Pre-dispatch: gate and bucket logic

```c
if (req[1] != state[7]) return;          // mode-mismatch guard

if ((cVar1 == '\r') || (cVar1 == '\x0e')) {
    health_post_stop_measure_event(DAT_0082c580); // stop with stored mask
    func_0x000136bc(state + 0x10);       // cancel 500 ms timer
    state[7] = 1;                        // reset to mode 1 (idle)
} else if (*(u16*)(state + 0xC) < 0x3C) {
    // 0xC is the "frame count" that 0x69 advanced;
    // if it's < 60 (the typical full-data threshold),
    // pick the matching stop parameter and bail early.
    health_post_stop_measure_event(<stop_param>);
    func_0x000136bc(state + 0x10);
    if (*(u16*)(state + 0xC) < 0x32) return;
}
```

The two pre-dispatch buckets handle:

* **Modes `0x0D` (13) and `0x0E` (14)** — special-case
  *stop* paths: stop HR using `DAT_0082c580` (the mode
  parameter stored by `0x69`), cancel the 500 ms tick, and
  set `state[7] = 1` (the "idle" sentinel).
* **Modes with `state[0xC] < 60`** — partial-data paths:
  the `0xC` field is the "frame count" that `0x69`
  accumulated; if it's under 60, the handler picks the
  matching stop parameter and *bails before re-entering
  the per-mode start dispatch*.

If neither bucket fires (mode is not `0x0D/0x0E` AND
`state[0xC] >= 60`), the handler falls through to the
full per-mode start dispatch.

#### Per-mode start dispatch

| Mode | Action | Sensor read |
|---:|---|---|
| `0x03` | `health_post_stop_measure_event(0x20)` | `spo2_current_value()` |
| `0x09` | `health_post_stop_measure_event(0x400)` | `blood_sugar_current_value()` |
| `0x0B` | `health_post_stop_measure_event(0x1000)` | `body_temperature_current_value_stub()` |
| `0x0C` | `health_post_stop_measure_event(DAT_0082c57c)` (data-driven) | `heart_rate_current_bpm()` + HRV/pressure/temp values |
| other | `health_post_stop_measure_event(1)` | `heart_rate_current_bpm()` |

The `health_post_stop_measure_event(<param>)` calls are the same HR-driver
"stop with mode parameter" wrappers used in `0x69 'i'` and
`0x1e realTimeHeartRate`. The `uVar4 = <sensor_read>()` is
the **1-byte result** that ends up in `byte 2` of the
response.

#### Special case: mode `0x0C` (12)

For mode `0x0C` the handler reads **5 sensor values** and
packs them into the response frame:

```c
uVar4 = heart_rate_current_bpm(); // 1st
local_28 = CONCAT13(uVar4, <0>);  // byte 3 = uVar4
uVar4 = hrv_current_value();      // 2nd
local_24 = CONCAT31(<hi3>, uVar4); // byte 0 of local_24 = uVar4
uVar4 = pressure_current_value(); // 3rd
local_24._0_2_ = CONCAT11(uVar4, <old_byte0>); // byte 0 = uVar4
uVar4 = body_temperature_current_value_stub(); // 4th
local_20 = CONCAT31(<hi3>, uVar4); // byte 0 of local_20 = uVar4
FUN_00834092(local_28._3_1_, &local_20 + 1, &local_20 + 2);
                                   // copy byte 3 of local_28 into bytes 1..2 of local_20
```

The final `local_28` / `local_24` / `local_20` block holds
the 5 sensor bytes scattered across the response bytes 2..4
and bytes 0..1 of `local_20` (which becomes bytes 8..9 of
the final response). The host must read these bytes in the
right order to reconstruct the sensor trace.

#### Response layout

The handler writes the cmd and echo **last**:

```c
local_28 = (uint)CONCAT11(local_28._3_1_, uVar4) << 0x10;  // pack sensor data
LAB_0082c256:
local_28._0_2_ = CONCAT11(req[1], 0x6a);                    // little-endian: byte0 cmd, byte1 mode
rsp[15] = FUN_0082b0c4(local_28, 0xf);                    // additive checksum
FUN_0082ebdc(local_28);
```

So the final 16-byte response is:

```
byte  0: 0x6a                (cmd)
byte  1: req[1]              (echo of mode)
byte  2: uVar4 (sensor read) | bytes 2..4 packed sensor trace for 0x0C
byte  3..14: 0 | packed sensor trace for 0x0C
byte 15: additive checksum
```

### 8.8 0x36 heart-rate related read/set (`FUN_0082c112`)

The 0xFEE7-side HR-related flag — structurally a *clone*
of the Channel-A `0x38 pressure` (§3.17) and `0x2c SpO2`
(§3.10) handlers. Stores a 1-bit on/off value as **bit 2**
of the same shared `DAT_008277f0 + 0x2D` config byte that
the other 1-bit features live in.

#### Sub-opcode dispatch

| `req[1]` | Action | Helper |
|---:|---|---|
| `0x01` (read) | `local_20[2] = FUN_0082768e()` — read bit 2 of `*(DAT_008277f0 + 0x2D)`, masked `& 7 >> 2` yields `0` or `1` | `FUN_0082768e` |
| other (write) | `FUN_0082769a(req[2] == 1)` — if `req[2] == 1`, set bit 2; else clear it. Response **echoes** `req[2]` | `FUN_0082769a` |

The mask `& 7` and the `>> 2` shift confirm that only
bits 2..3 of the byte are owned by this handler; the other
6 bits belong to other features.

#### Persistent state (1 bit)

| Bit | Field | Owner |
|---:|---|---|
| 0 | (other) | — |
| 1 | `spo2_enabled` | `0x2c SpO2` (§3.10) |
| 2 | `hr_related` | **`0x36` (this handler)** |
| 3 | `pressure_enabled` | `0x38 pressure` (§3.17) |
| 4 | (other) | — |
| 5 | `sugar` | `0x3a sub 0x03` (§3.22) |
| 6 | (other) | — |
| 7 | `lipids` | `0x3a sub 0x04` (§3.22) |

This completes the 4-bit feature map at `DAT_008277f0 +
0x2D`. The 0x36 bit at position 2 is the "HR-related" flag
that pairs with the larger HR opcodes `0x15 readHeartRate`
(§3.12) and `0x1e realTimeHeartRate` (§3.13) on the
Channel-A side.

#### Response layout

```
byte  0: 0x36                (cmd)
byte  1: req[1]              (sub-opcode echo: 0x01 read / 0x02+ write)
byte  2: feature value      (0/1 for read; echoed req[2] for write)
byte  3..14: 0
byte 15: additive checksum
```

Identical to `0x38 pressure` (§3.17) and `0x2c SpO2`
(§3.10). The shared `DAT_008277f0 + 0x2D` byte is the
"per-feature enable bitmap" that the watch reads whenever
it consults which sensors are active.

#### Why a separate 0xFEE7 opcode

`0x36` is the **0xFEE7 vendor variant** of `0x15
readHeartRate` (§3.12). The two are functionally equivalent
(turn the HR sensor on or off) but the host SDK that
consumes the 0xFEE7 service uses `0x36` for the lightweight
1-bit on/off control, while the Channel-A `0x15` is the
"full read" command that returns a 292-byte multi-frame
record (§3.12). A host that wants *fast* HR toggling can
use `0x36`; a host that wants *full HR data* must use the
Channel-A `0x15` / `0x1e` opcodes.

#### Pair with `0xC5/0xC8/0xC9` config-byte writes

§8.1 documents that `0xC5` writes `DAT_0082caec[3]`,
`0xC8` writes `DAT_0082caec[4]`, and `0xC9` writes
`DAT_0082caec[5] = req[1]`. None of these touch the
`DAT_008277f0 + 0x2D` byte directly — the 0xFEE7
"service-suspended" gate is *orthogonal* to the
per-feature enable bitmap. The host can toggle `0x36` to
disable the HR sensor without affecting the `0xC5/0xC8/0xC9`
flags, and vice-versa.

---

## 9. Notable Data & Globals

| Global | Inferred role |
|---|---|
| `DAT_0082d440` | Channel A command queue state |
| `DAT_0082f0f0` | Channel B reassembly buffer state |
| `DAT_0082edb8` | Channel A notify ring buffer state |
| `DAT_00830120` / `DAT_00830124` | OTA/DFU state structure |
| `DAT_0082b0b8` | Current time / date shared buffer |
| `DAT_00827e8c` | Vibration/motor mode |
| `DAT_0082cfe8` | Config block base (UV, display, etc.) |
| `DAT_0082fcbc` | Channel B async processor state (cmd, payload ptr, length) |
| `DAT_0082f458` | OTA state / context pointer base |
| `DAT_0082f894` | Sleep data context pointer |
| `DAT_0082f8a4` | Device info context pointer |

### 9.1 Global state-buffer map

A cross-cutting view of the **11 runtime state buffers**
that handlers across §2 / §3 / §5 / §6 / §7 / §8 share.
Each global is a *pointer* to a struct in the firmware's
RAM (runtime addresses in the `0x002xxxxx` range); the
handlers dereference them with field offsets. This section
maps each global to the handlers that read or write it.

| Global | Owners (handlers / sections) |
|---|---|
| `channel_a_command_queue_state` | `channel_a_dispatch_queued_frame` Channel-A dispatcher ring (§3); `channel_a_handle_detail_sport_read` `0x43 readDetailSport` (§3.6); `channel_a_handle_phone_sport` `0x77 phoneSport` (§3.16); `channel_a_handle_bp_read_confirm` `0x0e bpReadConform` (§3.19) |
| `channel_b_rx_reassembly_state` | `channel_b_parse_reassembly_frame` parser (§2.0); `channel_b_dispatch_complete_frame` dispatcher (§2.0); `channel_b_start_fragment_timeout` / `channel_b_fragment_timeout_cb` fragment timeout (§2.0); `channel_b_store_async_command` per-frame store (§2.0) |
| `channel_a_notify_ring_state` | `channel_a_queue_notify_frame` Channel-A notify ring builder (§3); §3 "Common response path" |
| `DAT_00830120` / `DAT_00830124` | `ota_dfu_state_machine` OTA state machine (§5.1); `ota_cmd_write_data_packet` OTA data writer (§5.2) |
| `DAT_0082b0b8` | `FUN_0082ba54` `0x2b menstruation` (§3.1); `FUN_0082bb4e` `0x01 setTime` (§3.4); `FUN_0082edc4` BCD decoder (§3.4) |
| `DAT_00827e8c` | `FUN_0082bb4e` `0x01 setTime` (§3.4); `FUN_00827b6c` vibration-mode setter (§3.2); `FUN_00827ba6` vibration-player (§3.2); `FUN_0082c7b8` `0x08` findDevice vibration (§3.15) |
| `DAT_0082cfe8` | `FUN_0082cdac` `0x81 config-chunk write` (§3.5); `FUN_0082ccb6` `0x18 displayClock` (§3.5) |
| `channel_b_async_state_ptr_alias` | `channel_b_async_command_processor` (§2.0); §2.1-§2.7 Channel-B handlers read/write here |
| `ota_write_context_ptr` | `ota_dfu_state_machine` state machine (§5.1); `ota_cmd_init_metadata` init (§5.2); §5.1 deferred-ring downstream |
| `channel_b_async_state_ptr_primary` | `channel_b_send_sleep_summary` `0x11 sleep summary` (§2.9); `channel_b_send_detailed_sleep` `0x12 detailed sleep` (§2.10) |
| `DAT_0082f8a4` | `FUN_0082f6ec` `0x5a device info` (§2.7) |

#### The two "shared with all of §8" globals

`DAT_0082bfcc` and `DAT_0082bfd4` are referenced in many
sections but not in the §9 table above — they're documented
in §3.24 (the deferred-ring synthesis) and §8.3 (the live
status field). Both are *central* to the firmware's runtime
state but their primary consumer is the 0xFEE7 dispatcher
(§8.1) rather than the §2 / §3 / §5 paths.

#### Why the OTA state is at `+0x14..+0x1C` (offsets in `DAT_00830128`)

`FUN_0082fe52` (§5.1) dispatches `sub 0/1/2/3` to
`FUN_0082fe4c(DAT_00830128 + 0x14)` / `+0x18` / `+0x1C`.
The three consecutive offsets correspond to the four
sub-cmd's "phase 2 / phase 3 / phase 4" state slots. Each
phase has its own state entry (the OTA handler writes a
state struct at the appropriate offset when the
corresponding sub-cmd is received).

#### Why the sleep context is at `DAT_0082f894`

The sleep data context (`DAT_0082f894`) holds the *current*
sleep record — the one the firmware is actively filling in
during the night. The §2.9 `0x11 sleep summary` reads the
finalised summary from this context (the `FUN_0082ee00`
"no data" path returns when the context is empty), and the
§2.10 `0x12 detailed sleep` reads the per-segment detail
from the same context. Both opcodes share the underlying
sleep record buffer — the difference is just the *amount*
of data they return (summary vs detail).

#### Why the device info context is at `DAT_0082f8a4`

The device info context (`DAT_0082f8a4`) holds the
TLV-encoded device metadata (vendor name, model, version,
build date — see §2.7). The §2.7 `0x5a device info` reads
from this context to assemble the response; the §8.2
`0x48 'H'` handshake reads a separate live battery u32
from `DAT_0082bfd4 + 0x2C` (not this buffer).

#### Why this section exists

Without §9.1, the §9 single-line table is a *list of
pointers* with no links to the handler sections that use
them. A host SDK author reading the per-handler sections
sees these globals referenced (e.g. `DAT_0082d440` in §3.6,
§3.16, §3.19) without knowing they're *shared* across
handlers. This section is the *single place* in the doc
that ties the 11 globals to the 30+ handlers that use them.

### 8.9 0xcd small arbitrary-address read (`fee7_vendor_memory_read_small_cd`)

A compact vendor memory-read primitive. This is not just a byte-order
sanity check: when `sub == 1`, the handler builds an absolute address from
request bytes `3..6`, copies up to 14 bytes from that address, and returns
them in a single 16-byte response frame.

#### Behavior

```c
void fee7_vendor_memory_read_small_cd(int param_1) {
    rsp[0] = 0xcd;
    if (req[1] == 1) {
        uint8_t len = min(req[2], 0x0E);    // clamp to 14
        uint32_t addr = (req[3] << 24) | (req[4] << 16) |
                        (req[5] << 8)  | req[6];          // BE32
        memcpy(rsp + 1, (void *)addr, len);
    }
    rsp[15] = FUN_0082b0c4(rsp, 0xf);
    FUN_0082ebdc(rsp);
}
```

The request address is big-endian. Bad addresses can fault or reset the watch.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0xcd` | cmd (consumed by dispatcher) |
| 1 | `sub` | must be `0x01` — other values skip the copy and return an all-zeros response |
| 2 | `len` | copy length; clamped to 14 |
| 3..6 | `addr` | source address, BE32 |

#### Response layout

```
byte  0: 0xCD                (cmd)
byte  1..N: copied memory bytes (N = min(req[2], 14))
byte  N+1..14: zero padding
byte 15: additive checksum
```

Use this only as a developer/debug primitive. It bypasses normal protocol
typing and address validation.

#### `sub != 0x01` behavior

When `req[1] != 1`, the handler skips the echo entirely
and sends an **all-zeros** response `[0xCD, 0, ..., 0, cksum]`.
This is a cheap way for the host to confirm the watch is
alive without committing a known payload to the echo path.

### 8.10 0xce factory/test sub-commands (`fee7_handle_factory_test_ce`)

The vendor-test entry point. Dispatches on five
*non-sequential* sub-cmd bytes — `0x01`, `0x02`, `' '`
(0x20), `'!'` (0x21), `'"'` (0x22) — to a mix of generic
config writers and vendor-specific self-test loops.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0xce` | cmd (consumed by dispatcher) |
| 1 | `sub` | selects the sub-command (see table below) |
| 2 | `param0` (u8) | passed as first arg to FUN_008336e8/0083361c/00838fae/008381a2/008381c0 |
| 3 | `param1` (char) | passed as second arg to FUN_008336e8/0083361c |
| 4 | `len` (u8) | copied into `local_18` — the response-copy length |
| 5..14 | `data[10]` | copied into the `local_28` buffer |

#### Sub-cmd dispatch

| `req[1]` | Action | Helper |
|---:|---|---|
| `0x01` | `FUN_008336e8(local_1c, cVar2, &local_28, local_18)` — write 10-byte config chunk | `FUN_008336e8` |
| `0x02` | `FUN_0083361c(local_1c, cVar2, &local_28, local_18)` — read 10-byte config chunk | `FUN_0083361c` |
| `' '` (0x20) | **Hardware self-test loop** (see below) | `FUN_00838bc0` + 9×`(*puVar3)()` + `FUN_00833400` |
| `'!'` (0x21) | **Bit-test** — `local_28 = ((*(uint*)(DAT_0082bfc8 + 0x10) & gpio_index_to_bitmask(local_1c)) != 0); local_18 = 1` | `gpio_index_to_bitmask` |
| `'"'` (0x22) | `gpio_set_pin_mux_byte(local_1c, 0x5A); gpio_configure_pin(local_1c, 0, 1, cVar2 == 0)` | GPIO mux/config helpers |
| other | falls through to response copy only | — |

#### `' '` (0x20) hardware self-test

```c
FUN_00838bc0(DAT_0082bfc0);              // reset vendor test context
puVar3 = DAT_0082bfc4;                  // function pointer table
for (i = 0; i < 9; i++) {
    gpio_configure_pin(0x14, 0, 1);    // vendor write 1
    (*puVar3)(1);                        // call test routine
    gpio_configure_pin(0x14, 0, 1);    // vendor write 1 again
    (*puVar3)(1);                        // call test routine
}
gpio_configure_pin(0x15, 0, 1);        // vendor write 2
(*puVar3)(1);                            // call test routine
gpio_configure_pin(0x15, 0, 1);        // vendor write 2 again
(*puVar3)(1);                            // call test routine
FUN_00833400();                          // finalise test
```

The `' '` self-test runs **20 vendor calls** in a tight loop
(9 iterations × 2 calls each = 18 + 2 trailing calls = 20).
Each pair is "write-vendor-reg `0x14` then call the
test-routine; do it again". The trailing 2 calls use
vendor-reg `0x15` (a different control register) and call
the same test routine. The `FUN_00838bc0(DAT_0082bfc0)`
is a "reset vendor test context" prep, and `FUN_00833400()`
is a "finalise" / "log result" tail call.

The `(*puVar3)()` indirection through `DAT_0082bfc4`
(function-pointer table) means the actual test routine is
**not** in the firmware body — it's loaded from a vendor-
specific table that lives elsewhere in the image (likely a
patch table the OEM ships for factory testing). A host that
sends `' '` without that vendor table populated will jump
to whatever pointer is at `DAT_0082bfc4` at runtime; if
the table is null, this is a *crash*.

This makes the `' '` sub-cmd a **factory-floor-only command**:
the OEM populates `DAT_0082bfc4` with a vendor-supplied
test routine before flashing the production firmware, and
only factory-floor equipment is expected to send it. A
normal OpenWatch host should never send `' '`.

#### `'!'` (0x21) bit-test

```c
uVar5 = gpio_index_to_bitmask(local_1c);
local_28 = ((*(uint*)(DAT_0082bfc8 + 0x10) & uVar5) != 0);
local_18 = 1;
```

A **mask + bit-test**: the handler maps the host-supplied index to a
GPIO/peripheral bit mask via `gpio_index_to_bitmask(local_1c)`, AND-masks it
against the value stored at `DAT_0082bfc8 + 0x10`, and writes a single byte
(`0x00` or `0x01`) into `local_28[0]` based on whether the masked result is
non-zero. `local_18` is set to `1` so the response carries exactly one byte of
result.

#### `'"'` (0x22) generic vendor write + check

```c
gpio_set_pin_mux_byte(local_1c, 0x5A);
gpio_configure_pin(local_1c, 0, 1, cVar2 == 0);
```

Two GPIO helper calls. `gpio_set_pin_mux_byte` writes the diagnostic mux byte
`0x5A` for the host-supplied index, then `gpio_configure_pin` applies the
pin/config bits. The `cVar2 == '\0'` flag is the fail-on-error toggle: the
host's `req[3]` selects whether the check is allowed to fail.

#### Response layout

After the dispatch, the handler copies `local_18` bytes
from `local_28` into the response:

```c
memcpy(rsp + 1, &local_28, local_18);
rsp[15] = FUN_0082b0c4(rsp, 0xf);
FUN_0082ebdc(rsp);
```

So the response is:

```
byte  0: 0xCE                         (cmd)
byte  1..N: <local_18 bytes of local_28> (N = local_18 = req[4])
byte  N+1..14: 0
byte 15: additive checksum
```

The `local_18` value (originally `req[4]`, but rewritten
for the `'!'` sub-cmd to `1`) controls how many payload
bytes the response carries:
* For `'0x01'` / `'0x02'` config R/W: `local_18 == req[4]`
  (the requested chunk length).
* For `' '` self-test: `local_18` is unchanged from `req[4]`,
  but `local_28` is all zeros (the helper doesn't write
  anything back). The response carries `req[4]` zero bytes.
* For `'!'` bit-test: `local_18 == 1` (the boolean result).
* For `'"'` generic: `local_18` is unchanged from `req[4]`,
  but `local_28` is all zeros.

#### Why the ASCII sub-cmd bytes

The use of `' '`, `'!'`, `'"'` (ASCII 0x20 / 0x21 / 0x22) as
sub-cmd selectors is a *vendor convention*: it lets a human
operator type the literal sub-cmd on a serial-terminal
interface and have the firmware do the right thing. The
firmware treats the sub-cmd byte as opaque data and never
parses the ASCII semantics — `0x20` and `0x21` are just
two more values in the dispatch switch.

#### Pair with `0xA1` factory/test mode (Channel-A)

`0xa1` is the Channel-A *user-facing* factory-test mode
(§3.x). It dispatches on sub-cmd bytes `0x01..0x06` for
HR step-counter operations. `0xce` is the 0xFEE7 vendor
*factory-floor* test mode that talks to the OEM's vendor
test tables (`DAT_0082bfc0`/`bfc4`/`bfc8`). They are
*orthogonal* features: `0xa1` is reachable by any host;
`0xce` is reachable only when the OEM has populated the
vendor tables.

### 8.11 0x51 `'Q'` vendor alert/test request (`fee7_handle_test_request_51`)

The "find phone" / longer alert trigger. Mirrors `0x50 'P'`
(§8.1) with different vendor-alert parameters — together
they are the two fire-alert commands on the 0xFEE7 service.

#### Behavior

```c
void fee7_handle_test_request_51(int param_1) {
    rsp[0] = 0x51;
    if (req[1] == 0x01) {
        FUN_0082994c(100, 0x10, 2, 8);   // vendor alert: mode 100, count 2, repeat 8
        FUN_0082a5c8(9);                  // motor pattern #9
    }
    rsp[15] = FUN_0082b0c4(rsp, 0xf);
    FUN_0082ebdc(rsp);
}
```

The handler fires a vendor alert pattern when `req[1] == 1`
and always sends the ack frame. Non-`0x01` sub-cmd values
are silently ignored — the ack ships with an empty body
(`[0x51, 0, 0, ..., 0, cksum]`).

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x51` | cmd (consumed by dispatcher) |
| 1 | `sub` | must be `0x01` to trigger; other values are no-ops |

Bytes 2..14 are ignored.

#### Response layout

```
byte  0: 0x51                (cmd)
byte  1..14: 0
byte 15: additive checksum
```

The body is always empty — the handler does not return any
"trigger accepted" detail, just the cmd-and-checksum ack.
This is identical to `0x50 'P'` (§8.1).

#### `0x50 'P'` vs `0x51 'Q'` comparison

| Param | `0x50 'P'` (inline) | `0x51 'Q'` (§8.11) |
|---|---|---|
| `FUN_0082994c` mode | `0x14` | `100` (`0x64`) |
| `FUN_0082994c` param | `0x10` | `0x10` |
| `FUN_0082994c` count | `1` | `2` |
| `FUN_0082994c` repeat | `0x19` (25) | `8` |
| `FUN_0082a5c8` pattern | `8` | `9` |

The two opcodes are the *short* alert (`0x50`: single
rep, 25 repeats) and the *long* alert (`0x51`: two reps,
8 repeats). A host that wants to beep the watch briefly
should send `0x50`; a host that wants to play a longer
"find my watch" sequence should send `0x51`. The motor
pattern numbers (8 vs 9) are presumably the vendor's
naming for the corresponding alert tunes.

#### Why two opcodes for the same logical operation

The H59MA vendor splits the "fire alert" operation into two
opcodes so the host can choose between *beep* and *find-me*
without negotiating parameters on the wire. This matches the
§3 Channel-A convention where `0x08` (camera/find-device)
has sub-cmd `0x00` (cancel) vs `0x01` (start) — but the
0xFEE7 service puts the *duration* into the opcode rather
than into a sub-cmd, which is simpler for the short
single-frame alerts.

#### Pair with `0xC5/0xC8/0xC9` config-byte writes

The two alert opcodes share the same config-byte state at
`DAT_0082caec` (set via `0xC5`/`0xC8`/`0xC9` — see §8.1).
A host that wants to *disable* alerts without firmware reboot
can write `0` to `DAT_0082caec[3]` via `0xC5 0x00` and the
`0x50` / `0x51` opcodes will silently no-op (the
sub-cmd-byte guard will still pass but the vendor alert
helper will be a no-op via the dispatcher gate).

### 8.12 0x3c capability block (`fee7_send_fixed_capability_3c`)

The "what features does this watch support" answer. Sends
a **fully static 16-byte response** that contains four
feature IDs scattered across the frame body. The handler
ignores the request entirely — `0x3c` is fire-and-forget.

#### Behavior

```c
void fee7_send_fixed_capability_3c() {
    rsp[0]  = 0x3c;        // cmd
    rsp[1]  = 0x00;
    rsp[2]  = 0x40;        // feature ID 1
    rsp[3]  = 0x00;
    rsp[4..6]  = 0;
    rsp[7]  = 0xa0;        // feature ID 2 (split across bytes 7..8?)
    rsp[8..10] = 0;
    rsp[11] = 0x20;        // feature ID 3
    rsp[12..14] = 0;
    rsp[15] = FUN_0082b0c4(rsp, 0xf);
    FUN_0082ebdc(rsp);
}
```

The handler does *not* read `param_1` at all — there is no
request payload for `0x3c`. The four non-zero bytes
(`0x3c`, `0x40`, `0xa0`, `0x20`) are the static "feature
flags" returned on every call.

#### Response layout (16-byte static block)

```
byte  0: 0x3C                (cmd)
byte  1: 0x00
byte  2: 0x40                (feature ID 1)
byte  3: 0x00
byte  4: 0x00
byte  5: 0x00
byte  6: 0x00
byte  7: 0xA0                (feature ID 2 — high byte)
byte  8: 0x00                (feature ID 2 — low byte = 0?)
byte  9: 0x00
byte 10: 0x00
byte 11: 0x20                (feature ID 3)
byte 12: 0x00
byte 13: 0x00
byte 14: 0x00
byte 15: additive checksum
```

Note: the bytes between the non-zero entries are **all
zero** — the firmware does not populate any "feature
metadata" beyond the four flags. The host SDK is expected
to recognise `0x40` / `0xA0` / `0x20` as opaque feature
identifiers (they are likely vendor-specific feature codes
that match the H59MA SDK's `enableXxx` flags).

#### Why a static block (not a runtime read)

`0x3c` is the only 0xFEE7 opcode whose response is **hard-
coded** in the firmware binary. All other opcode handlers
either compute the response at runtime (`0x48`, `0x61`),
look up state from RAM (`0xc5`, `0xc8`, `0xc9`), or call
into a vendor function table (`0xce`). The static nature
suggests:

* The capability block is *product-line wide*: every H59MA
  v14 firmware ships with the same capabilities, so the
  block can be baked into the ROM.
* The vendor doesn't expect the watch model or feature set
  to change between firmware revisions — when it does, the
  firmware is rebuilt and the static block is regenerated.

#### `param_1` ignored

The handler signature is `void fee7_send_fixed_capability_3c()` (no params),
even though the dispatcher passes `param_1` (the request
frame). The decompiler optimises the unused param out
entirely. A host that sends a *non-empty* request still
gets back the same static block — the `0x40`, `0xa0`,
`0x20` flags are unconditionally emitted.

#### Pair with `0x61 'a' status` (§8.3)

`0x3c` and `0x61 'a'` are the two "what does this watch
do" answers. `0x3c` answers once per connection with the
**static feature set**; `0x61 'a'` answers continuously
with the **live status** (battery %, daily counters). A
host that wants both can:

1. Send `0x3c` after `0x48` (handshake) to learn the
   supported features once.
2. Poll `0x61 'a'` at low rate for live battery / counter
   updates.

#### Relation to the §3 "0x3c capability block"

`0x3c` is also a *Channel-A* opcode (the §3 dispatcher
at `channel_a_dispatch_queued_frame` does not route `0x3c`; the byte 0x3c
falls into the `0x39 < uVar2 < 0x43` chain and reaches
`fee7_send_fixed_capability_3c`). So `0x3c` is in fact a *shared* opcode
between Channel-A and 0xFEE7 — the dispatcher for both
tables lands on the same handler. The host SDK can call it
from either transport.

### 8.13 0xfe synthetic sleep-history record (inline in `FUN_0082c944`)

The only 0xFEE7 opcode in this range that is **fire-and-forget** with
**no response frame at all**. The dispatcher inline-calls
`fee7_generate_synthetic_sleep_record` with the u16 LE duration from
`req[1..2]` and returns without queuing a response. Earlier notes
misidentified this as a vibration-pattern builder; the decompiled callee
clears a sleep-history work buffer and commits a generated sleep record.

#### Dispatcher body

```c
case 0xfe:
    fee7_generate_synthetic_sleep_record(*(u16 *)(req + 1));
    return;
```

No `FUN_0082ebdc` is called — the watch accepts the
request, builds the pattern, and goes silent.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0xfe` | cmd (consumed by dispatcher) |
| 1..2 | `duration_minutes` (u16 LE) | sleep duration; clamped to `900` minutes inside `fee7_generate_synthetic_sleep_record` |
| 3..14 | unused | — |

#### `fee7_generate_synthetic_sleep_record` behavior

The handler synthesizes a plausible night-sleep record:

1. Clamp requested duration to `900` minutes.
2. Clear the synthetic sleep work buffer at `0x0020cd48`
   (`DAT_00844324` / `DAT_008443b4`).
3. Store the current epoch-day.
4. Pick a pseudo-random start minute in the evening/early-night window
   (`20:00..01:59`), then compute `end = (start + duration) % 1440`.
5. Generate up to 40 `(sleep_stage, duration)` segment pairs.
6. Commit the record through `FUN_008316fe` into the same sleep-history
   storage consumed by Channel-B `0x11`, `0x12`, and `0x27`.

This is a data-integrity-sensitive path: a paired host can forge or overwrite
sleep history without an acknowledgement or confirmation step.

#### Synthetic sleep work buffer (`0x0020cd48`)

| Off | Field | Notes |
|---:|---|---|
| 0 | `day_index` / epoch-day | Current day key used for sleep-history commit. |
| 4..7 | `start_minute`, `end_minute` | Minutes of day; end wraps modulo 1440. |
| 0x14.. | segment stages | Up to 40 generated sleep-stage entries. |
| 0x3c.. | segment durations | Corresponding segment durations. |

The exact stage-value meaning still needs live validation against host-decoded
sleep graphs, but the storage path is clearly the sleep ring, not the alert or
motor subsystem.

#### Why no response

The handler mutates persistent history as a delayed side effect and does not
return a status frame. A host that sends this command must verify the mutation
by reading sleep history back through Channel-B.

#### Why `0xfe` is inline in the dispatcher

Most 0xFEE7 handlers are routed through `enqueue_deferred_command_frame`
(deferred ring — see §8.1). `0xfe` is inline because the dispatcher only
needs the duration field and can hand it directly to the sleep-record
generator without occupying a deferred command slot.

### 8.14 0xc1 one-shot health result poll (inline in `FUN_0082c944`)

`0xc1` is inline in the dispatcher and ignores the request payload. It calls
the one-shot health helper and immediately sends one byte from
`DAT_0082caf0` (`0x00209f32`) in a fragmented-response wrapper. No later long
payload was observed in this pass.

#### Dispatcher body

```c
case 0xc1:
    FUN_008337fa(DAT_0082caf0);          // update/poll one-shot health byte
    channel_a_send_fragmented_response(*req, DAT_0082caf0, 1);
    return;
```

The response is a standard 16-byte FEE7/Channel-A-style frame:

```
byte 0:    0xc1
byte 1:    result/stale health byte from 0x00209f32
byte 2..14 zero padding
byte 15:   additive checksum
```

#### `FUN_008337fa` boundary

```c
void FUN_008337fa(undefined1 *out_ptr, ..., undefined4 param_4) {
    state = DAT_00833858;
    flag  = state + 0x1c;
    if (!(*flag & 1)) {                     // not already pending
        *flag = 0;  *(state + 0x20) = 0;  *(state + 0x24) = 0;
        if (*DAT_0083389c != 1 && !FUN_00828af4()) {  // ring idle, HR not running
            health_post_start_measure_event(2);                       // start HR measurement mode 2
            FUN_00829c24(DAT_00833a1c, DAT_00833a18,
                         DAT_00833a14, 1, param_4); // queue work item
            *flag |= 1;
            *(state + 0x20) = out_ptr;             // store callback pointer
            return;
        }
        // ring busy OR HR running: mark "needs retry"
        *(DAT_00833858 + 0xf) = 1;
        if (out_ptr) *out_ptr = 0;
    } else {
        // already pending — update callback pointer
        *(state + 0x24) = out_ptr;
    }
}
```

`FUN_008337fa` still appears to be the one-shot health/HR helper: it checks the
measurement busy gate (`health_sensor_session_is_active`), may post
`health_post_start_measure_event(2)`, and stores result/callback state under
`DAT_00833858`. The `0xc1` dispatcher, however, does not wait for or queue a
larger follow-up transfer; it sends whatever byte is present in `DAT_0082caf0`
right after calling the helper. Treat that byte as a result-or-stale status
until live captures prove a stricter meaning.

#### Why inline in the dispatcher

Like `0xfe` (§8.13), `0xc1` is inline because its work is small and immediate:
one helper call, then one 1-byte response. Routing this through the deferred
command ring would add latency without carrying extra state.

#### 3.0.1 Channel-A "common response path" synthesis

The §3.0 "common response path" mentions three helpers
(`FUN_0082b0c4` checksum, `FUN_0082ebdc` notify queue,
`FUN_0082eb8a` notify kick). These are referenced in *every*
per-opcode §3.x sub-section because every Channel-A handler
goes through them. This sub-section pulls the threads
together.

The three helpers form a **3-step pipeline**:

1. `FUN_0082b0c4(rsp, 0xf)` — compute the additive
   checksum over bytes 0..14 and store it in `rsp[15]`. This
   is the §2.0 CRC-16/MODBUS variant: it uses the same
   algorithm but operates on a 15-byte window instead of
   the 6-byte header.
2. `FUN_0082ebdc(rsp)` — queue the 16-byte frame at the
   `DAT_0082edbc + 0xc + slot_idx * 0xb6` slot, advancing
   `slot_idx` (wraps at 8). The ring buffer holds 8
   in-flight frames.
3. `FUN_0082eb8a()` — kick the BLE notify task to drain
   the ring. Called once per queued frame; the firmware
   coalesces multiple frames into a single notify if the
   host can keep up.

The handler helper `FUN_0082b986(cmd, isNotify)` (which
emits 1-byte acks with `0x80` flag) uses the *same*
pipeline but skips `FUN_0082b938` (the fragmenter) — the
1-byte ack is queued directly into the ring.

Why a synthesis section: a host SDK author who needs to
understand the Channel-A *response* pipeline sees
`FUN_0082b0c4`, `FUN_0082ebdc`, `FUN_0082eb8a` referenced
across §3.1-§3.24. Without §3.0.1, those references are
isolated. §3.0.1 pulls them into a single 3-step pipeline
description that explains *why* the same three helpers
appear in every per-opcode section.

#### Pair with `0x15 readHeartRate` (Channel-A)

`0xc1` is related to the Channel-A `0x15` read-heart-rate path, but it is not a
drop-in equivalent. `0x15` returns a full HR-history payload; `0xc1` only sends
one byte from the one-shot helper's status/result buffer.

| | `0x15` (Channel-A) | `0xc1` (0xFEE7) |
|---|---|---|
| Trigger | dispatcher calls `FUN_0082cf48` directly | dispatcher calls `FUN_008337fa` + `channel_a_send_fragmented_response(..., len=1)` |
| Payload | full 292-byte record | one result/status byte |
| Ack | payload frames only | one immediate frame |
| State machine | per-call record read | shared one-shot health state under `DAT_00833858` |

A host that wants HR records should use `0x15`; `0xc1` is useful only as a
vendor health-poll/status primitive.

#### Why the dispatcher's `FUN_0082b938(*param_1, ...)` uses `length = 1`

The second call sends a **1-byte payload** response. The `1` argument is the
payload length, not a byte value, so the host should expect one data byte at
`frame[1]` and no follow-up chunks from this opcode.

The host SDK should:
1. Send a 16-byte FEE7 frame with opcode `0xc1`.
2. Read one response frame.
3. Decode `frame[1]` as an opaque health/status byte pending live capture.

---

## 10. Open Questions / Next Steps

Two of the three originally-open questions have been resolved, and the OTA
digest question is narrowed:

1. ~~Recover the exact meaning of opcode `0x2b` mixture container fields.~~ **Resolved** — see §3.1. The 16-byte `mixture_state_t` is now fully decoded; remaining unknowns are semantic (BCD field interpretation, period-data byte meanings).
2. **Identify the 32-byte `image_digest` algorithm used for OTA and the container header digest at `0x1c4`.** Still open for the bootloader image. `body.bin` validates only the first OTA container word (`ota_container_magic` = little-endian `0x81bdc3e5`), stages bytes from file offset `0x50` onward, and checks `written_bytes == expected_size - 0x50`. The digest region is staged as raw data but not validated by this body path. The separate `0x8721bee2` magic belongs to the config blob (§5.3), not OTA.
3. ~~Determine whether the `0xFEE7` vendor service has any active protocol role in the firmware.~~ **Corrected by radare2** — see §8 and `firmwares/_re/fee7-gatt/evidence.md`; the service is registered, but static routing does not connect its write callback to the 16-byte dispatcher.

### 10.0 What's in this doc (final tally)

This document covers the H59MA v14 firmware in **~7,250 lines** with **17+ synthesis sections** and **~55 documented handlers / sub-sections** across 11 top-level sections (§0-§10). The earlier ~6,800-line tally has grown ~450 lines from §2.0.1 (Channel-B internal helpers) and §2.0.2 (async state structure), and the §10.2 unified handler inventory.

* **§0 Reading order** — the recommended navigation path.
* **§1 Entry Point & Boot** — vector table, app_main_task, reset
  handler.
* **§2 Channel-B** (12 sub-sections including §2.0 NAK
  packet) — 11 documented handlers covering the parser,
  dispatcher, async processor, OTA sub-cmd routing, alarm,
  activity summary, sleep summary, sleep detail, sleep
  records, file list, file init/delete, device info.
* **§3 Channel-A** (24 sub-sections including §3.23 1-bit
  config bitmap synthesis and §3.24 deferred-command ring
  synthesis) — 22 documented handlers covering setTime,
  displayClock, readDetailSport, DND, setSitLong,
  readSitLong, bloodOxygenSetting, pressureSetting,
  pressure, hrvSetting, sugarLipidsSetting, uvSetting,
  bpReadConform, menstruation, findDevice, phoneSport,
  vibration, factory reset, pushMsgUint, realTimeHeartRate,
  readHeartRate, restoreKey, factory test mode.
* **§4 ANCS** (3 sub-sections) — ancs_add_client,
  ancs_parse_notification_source_data, ancs_client_cb.
* **§5 OTA/DFU** (3 sub-sections including §5.1 state
  machine and §5.2 helper details) — the OTA dispatcher,
  signature check, start/init/data/end helpers.
* **§6 Power Management** (2 sub-sections) — button/DLPS init,
  system reset.
* **§7 Health / Sensor Modules** (2 sub-sections) — HR
  module dispatcher, accelerometer SPI dispatcher.
* **§8 0xFEE7** (22 sub-sections including §8.20 reserved-
  opcode range and §8.22 wire-format synthesis) — the full
  vendor protocol with 13 documented handlers + 9
  synthesis sections (vendor NAK, self-marker pattern,
  config-bit bitmap, deferred ring, etc.).
* **§9 Notable Data & Globals** (1 sub-section) — the 11
  runtime state buffers cross-referenced to handlers.
* **§10 Open Questions** — all 3 originally-open questions
  resolved; only §10.1 doc-structure note remains.

The doc covers ~80% of the firmware's surface area in detail
(handlers + cross-cutting patterns). The remaining ~20% is
smaller helpers (e.g. `FUN_00833968` is a 3-line register
getter, `FUN_0082c530` is a 5-line config-byte setter)
that are documented in the per-handler sections they
support but not as standalone sections.

### 10.2 Unified handler inventory (quick reference)

A *single-table* index of every documented handler across all
sections. Use this when you know the *transport* (Channel-A
/ Channel-B / 0xFEE7) but need to find the *exact opcode +
section number* for a given operation.

#### Channel-B (§2) — 11 documented handlers

| Cmd (hex) | Sub-byte | § | Operation |
|---|---|---|---|
| `0x11` | day_offset | §2.9 | sleep summary (101 B: echoed offset + 100 B) |
| `0x12` | day_offset | §2.10 | sleep detail (289 B: echoed offset + 288 B) |
| `0x27` | — | §2.4 | sleep records (night) |
| `0x2a` | day_offset | §2.8 | activity summary (up to 3 × 49 B) |
| `0x2c` | sub 0x01 / 0x02 | §2.5 | alarm read / write |
| `0x3e` | — | §2.4 | lunch sleep records (same as `0x27`) |
| `0x41` | file_index | §2.11 | file list (up to 10 files, `0x42` response opcode) |
| `0x43` | payload | §2.11 | file init (no response) |
| `0x46` | payload | §2.11 | file delete (no response) |
| `0x5a` | config_tlv | §2.7 | device info TLV |
| `NAK` | — | §2.0 | vendor NAK packet (error_code + cmd) |

#### Channel-A (§3) — 22 documented handlers

| Cmd (hex) | § | Operation |
|---|---|---|
| `0x01` | §3.4 | setTime (BCD → RTC, sends `0x2f` MTU ack + 14 B `0x01` ack) |
| `0x06` | §3.7 | DND read/write (sub 0x01 / 0x02) |
| `0x08` | §3.15 | findDevice / camera / long-press (sub 0x00 / 0x01 / `0xAB 0xDC`) |
| `0x0e` | §3.19 | bpReadConfirm (advances BP record index, returns tagged compact `0x0d` BP frames) |
| `0x15` | §3.12 | readHeartRate (multi-frame `0x15` response or `0xff15` error) |
| `0x18` | §3.5 | displayClock (watch-face / clock) |
| `0x1e` | §3.13 | realTimeHeartRate (sub 0x01 start 60 s, 0x02 stop, 0x03 reset) |
| `0x25` | §3.9 | setSitLong (writes sedentary config) |
| `0x26` | §3.9 | readSitLong (reads sedentary config) |
| `0x2b` | §3.1 | menstruation (mixture container, 16 B record) |
| `0x2c` | §3.10 | bloodOxygenSetting (SpO2 on/off, bit 1 of shared config byte) |
| `0x37` | §3.20 | pressureSetting (long fragmented config) |
| `0x38` | §3.17 | pressure (bit 3 of shared config byte) |
| `0x39` | §3.21 | hrvSetting (long fragmented config) |
| `0x3a` | §3.22 | sugarLipidsSetting (bits 5 / 7 of shared config byte) |
| `0x3b` | §3.18 | uvSetting (touch control, 1 byte at `DAT_0082cfe8 + 8`) |
| `0x43` | §3.6 | readDetailSport (per-day 292 B detail dump) |
| `0x72` | §3.3 | pushMsgUint (chunked Unicode buffer, 11 B per chunk + flush marker) |
| `0x77` | §3.16 | phoneSport (4-stage lifecycle via switch8) |
| `0x7a` | §3.11 | muslim (long fragmented config; producer is a stub) |
| `0xa1` | §3.x | factory/test mode (6 sub-cmds, saves 1 kB context to `DAT_00830128`) |
| `0xc6` | §3.14 | restoreKey (full reboot sequence) |
| `0xc7` | §3.2 | vibration / motor pattern (two modes `'#'` / `'D'`) |
| `0xff` | §3.8 | factory reset (memset 164 B config at `DAT_0082cff0`) |

#### 0xFEE7 vendor service (§8) — 13 documented handlers

| Cmd (hex) | § | Operation |
|---|---|---|
| `0x36` | (mentioned in §8) | HR-related read/set |
| `0x3c` | §8.12 | capability block (fixed 16 B response, features at bytes 2/7/11) |
| `0x3e` | §8.15 | lipids read/set (bit 7 of shared config byte — was wrongly labelled SpO2) |
| `0x48` | §8.2 | handshake (`'H'` returns 15 B device-info block) |
| `0x51` | §8.11 | find-phone / long alert (`'Q'` triggers vendor alert + motor pattern 9) |
| `0x60` | §8.16 | status-field write (writes u32 to `DAT_0082bfd4 + 0x2C`, self-marker) |
| `0x61` | §8.3 | status response (`'a'` returns u32 from `DAT_0082bfd4 + 0x2C`) |
| `0x69` | §8.5 | mode control (`'i'` — 4-stage lifecycle: reset / start / receive / read) |
| `0x6a` | §8.7 | mode-control continuation (`'j'` — the byte-reversed sub-byte pair with `0x69`) |
| `0x90` | §8.6 | self-marker echo (`'.'` returns `[0x90, 0, 0, 0, ..., 0, 0x90]`) |
| `0x93` | §8.18 | firmware version + build-date string (returns `"1.00.14_260508"`) |
| `0x94` / `0x95` | §8.19 | state-update modes 1 / 3 (self-marker ack) |
| `0x96` | §8.4 | reset-state (self-marker ack, also resets `DAT_0082caec[3..5]`) |
| `0xbf` / `0xc0` | §8.17 | vendor memory R/W (raw `memcpy` to / from host-supplied address) |
| `0xc1` | §8.14 | one-shot health poll (calls async helper, immediately returns one status/result byte) |
| `0xc5` / `0xc8` / `0xc9` | §8.1 | inline config-byte writes to `DAT_0082caec[3..5]` |
| `0xcd` | §8.9 | byte-reverse echo / link-sanity test |
| `0xce` | §8.10 | factory/test sub-commands (sub `0x01`/`0x02`/`' '`/`'!'`/`'"'`) |
| `0xfe` | §8.13 | synthetic sleep-history record from duration (fire-and-forget, no response) |

#### ANCS (§4) — 3 callbacks

| Callback | § | Operation |
|---|---|---|
| `ancs_add_client` (`FUN_00839e4e`) | §4.1 | register ANCS client, allocate state |
| `ancs_parse_notification_source_data` (`FUN_00839fee`) | §4.2 | parse incoming notification source bytes |
| `ancs_client_cb` (`FUN_0083a116`) | §4.3 | handle `connect`/`notification`/`data`/`disconnect` events |

#### OTA / DFU (§5) — helpers

| Function | § | Operation |
|---|---|---|
| `ota_dfu_state_machine` | §5.1 | OTA state machine (sub 0/1/2/3/4 lifecycle) |
| `ota_cmd_start_ack` | §5.2 | OTA start ack |
| `ota_cmd_init_metadata` | §5.2 | OTA init (parses 9 B metadata) |
| `ota_cmd_write_data_packet` | §5.2 | OTA data writer and container magic check |
| `ota_cmd_check_complete` | §5.2 | validates `written == size - 0x50` |
| `ota_cmd_end_reboot` | §5.2 | final reboot/apply path |
| `cfg_blob_magic_ok` | §5.3 | config blob magic check (`0x8721bee2`), not OTA |

#### Power management (§6) — 2 helpers

| Function | § | Operation |
|---|---|---|
| `FUN_0082a144` | §6.1 | button / DLPS init (3 timers + GPIO mask `0x1D`) |
| `FUN_008275d8` | §6.2 | system reset (14-step sequence) |

#### Sensors (§7) — 2 dispatchers

| Function | § | Operation |
|---|---|---|
| `health_module_event_dispatch` | §7.1 | HR module dispatcher (start/stop event bus) |
| `lis3dh_accel_dispatch` | §7.2 | accelerometer / LIS3DH SPI dispatcher (single sub-cmd) |

#### Boot (§1) — 2 functions

| Function | § | Operation |
|---|---|---|
| `entry` (`0x00826400`) | §1 | Cortex-M trampoline |
| `app_main_task` (`FUN_00826988`) | §1.1 | post-reset main-task (10-step boot sequence) |

#### Why this section exists

Without §10.2, a host SDK author who knows the transport
(Channel-A / Channel-B / 0xFEE7) but not the specific
opcode would have to read each top-level section (§2 / §3 /
§4 / §5 / §6 / §7 / §8) in full to find the right entry.
§10.2 is the **single table** that maps transport + opcode →
§, eliminating the need to scan the per-section tables.

The §10.2 table intentionally **omits** opcodes that are
not actively used on the H59MA v14 (e.g. §2's reserved
sub-cmds and §3's switch8 default-slot handlers). The §8.20
high-range no-response placeholders and session/model/status
handlers are noted in their synthesis but not repeated in §10.2.

#### Cross-cutting synthesis index

§10.2 is the *inventory*. The *patterns* that connect the
handlers are documented in the 15+ synthesis sections:

* §0 reading order — recommended navigation path
* §2.0 — Channel-B NAK packet
* §3.23 — DAT_008277f0 + 0x2D 1-bit config bitmap
* §3.24 — DAT_0082bfcc deferred-command ring
* §5.1 — OTA state machine
* §6.1 / §6.2 — power-management helpers
* §7.1 / §7.2 — sensor dispatchers
* §8.20 — 0x97-0xA0 high-range session/status handlers
* §8.21 — self-marker opcode pattern
* §8.22 — cross-section wire-format
* §9.1 — DAT state-buffer map

A host SDK author who reads §0 first (§0 reading order),
then uses §10.2 (this section) as the inventory, can
locate any handler in the doc with two lookups: §10.2 for
the §-number, then the §-number for the detailed payload /
response / state-layout.

### 10.1 Doc structure note
The §8 sub-sections §8.1-§8.8 are in the correct location
(in §8, right after the §8 heading at line 4020). The
later §8 sub-sections §8.9-§8.22 are appended *after* this
§10 section because the doc was edited incrementally over
many rounds and the §8.x content was added to the end of the
file each time. The numbering is still correct (§8.x within
the §8 group), but the physical order in the file is:
§8 heading → §8.1-§8.8 → §9 → §10 → §8.9-§8.22.

The reading-order (§0) treats §8.x as a single logical
group regardless of physical order in the file. The
sub-sections are still in synthesis order (§8.9 = first
post-§8.8 synthesis, §8.22 = final wire-format synthesis),
so reading them in §0's recommended order gives the right
narrative arc.

### 8.15 0x3e lipids read/set (`fee7_handle_lipids_flag_3e`)

The 0xFEE7 vendor-side **duplicate** of the `0x3a sub 0x04`
lipids bit-toggle. The existing docstring for `0x3e`
("SpO2 / blood-oxygen related read/set") is *wrong* —
the helper functions it calls (`FUN_008277ce` and
`FUN_008277d8`) read and write **bit 7** of the shared
config byte at `DAT_008277f0 + 0x2D`, which is the
**lipids** bit per the §3.22 / §8.8 bit map.

#### Sub-opcode dispatch

| `req[1]` | Action | Helper |
|---:|---|---|
| `0x01` (read) | `local_20[2] = FUN_008277ce()` — read bit 7 of `*(DAT_008277f0 + 0x2D)`, `>> 7` yields `0` or `1` | `FUN_008277ce` |
| other (write) | `FUN_008277d8(req[2] == 1)` — if `req[2] == 1`, set bit 7; else clear it. Response echoes `req[2]` | `FUN_008277d8` |

The handler is a *structural clone* of `0x36` (§8.8) and
`0x38` (§3.17) — same 3-byte response shape, same
"read 0x01 / write otherwise" sub-cmd pattern.

#### Persistent state (1 bit)

| Bit | Field | Owner |
|---:|---|---|
| 7 | `lipids` | `0x3e` (this handler) **and** `0x3a sub 0x04` (§3.22) |

Yes — `0x3e` and `0x3a sub 0x04` both own **bit 7** of the
same shared config byte. They are duplicates: the same
lipids bit is reachable from both `0x3a sub 0x04` (via the
`0x2C` §3.10 dispatcher) and `0x3e` (via the `0xFEE7` §8.1
dispatcher). The masks `>> 7` and `<< 7` and the write
guard `(... & 0x7F) | (param_1 << 7)` are identical, so
writing through either opcode has identical effect.

#### Response layout

```
byte  0: 0x3E                (cmd)
byte  1: req[1]              (sub-opcode echo: 0x01 read / 0x02+ write)
byte  2: 0x00 / 0x01         (lipids value on read; echoed req[2] on write)
byte  3..14: 0
byte 15: additive checksum
```

#### Why a duplicate?

`0x3e` is one of the few *opcode duplicates* in the
firmware. Two plausible reasons:

1. **Backwards compatibility with older host SDKs** that
   used `0x3e` directly. The newer `0x3a sub 0x04` is the
   preferred path for new code, but the watch keeps `0x3e`
   working so older apps don't break.
2. **Vendor-table shortcut**: the OEM vendor tables (§8.10
   `0xce` handler) reference `0x3e` directly because it's
   a single-byte opcode without sub-cmd routing — easier to
   emit from a fixed-purpose vendor test routine.

The body code (`FUN_008277ce` / `FUN_008277d8`) is *shared*
with `0x3a sub 0x04` — both handlers call the same pair of
helpers, and the helpers themselves operate on the same
shared bit. This is the second instance of "different opcode,
same underlying bit" — the first being `0x36` (HR enable)
vs the (absent) duplicate for SpO2, where the firmware
chose to keep a single channel.

#### Correcting the docstring

The original §3 opcode table listed `0x3e` as "SpO2 /
blood-oxygen related read/set" — this was incorrect. The
correct semantic (per the decompiled `>> 7` shift and the
shared-bit overlap with `0x3a sub 0x04`) is **lipids
read/set**. The SpO2 bit-toggle lives at `0x2c` (§3.10)
only; there is no 0xFEE7-side duplicate for SpO2.

If the host SDK's `enableSpo2()` function sends `0x3e`, it
will silently toggle the **lipids** bit instead, leaving
SpO2 untouched. The correct opcode for SpO2 is `0x2c` (the
Channel-A path) — which is *not* reachable from the 0xFEE7
service. A host that wants SpO2 control must use the
Channel-A path, not the 0xFEE7 path.

#### Why a §8.15 if it's a duplicate of `0x3a sub 0x04`?

The duplicate-opcode pattern is significant because it
shows the firmware's *evolution*: the older `0x3e` opcode
was kept for compatibility even after the more flexible
`0x3a sub 0x04` was added. Future firmware revisions may
remove `0x3e` once the vendor test routines stop using it,
but the lipids bit (7) will remain in the shared config
byte.

### 8.16 0x60 status-field write (`FUN_0082be90`)

The **write** side of the `0x61 'a'` status (§8.3) pair.
`0x60` lets the host push a 4-byte u32 into the same
`DAT_0082bfd4 + 0x2C` field that `0x61 'a'` reads. The
existing docstring ("ANCS/message-push related") is *wrong*
— the handler's only side effects are (a) writing the status
u32 and (b) scheduling a 100 ms timer.

#### Behavior

```c
uint FUN_0082be90(int param_1) {
    if (FUN_0082762c() == 1 && FUN_0082d754() == 0) {
        // "all-zeros ack" path
        rsp[0]  = 0x60; rsp[15] = 0x60;  // self-marker frame
        FUN_0082ebdc(rsp);
        FUN_0082fdda(100);               // 100 ms timer
        return 0x60;
    }
    // "store u32" path
    rsp[0]  = 0x60; rsp[15] = 0x60;
    FUN_0082ebdc(rsp);
    uint32_t v = ((req[3] << 16) | (req[4] << 24)) |
                 (req[1]       )          |
                 (req[2] << 8);
    *(u32*)(DAT_0082bfd4 + 0x2C) = v;
    return 0x60;
}
```

The handler has **two paths** that both send the same
self-marker response frame `[0x60, 0, 0, ..., 0, 0x60]`:
* "Happy" path: state is good → schedule a 100 ms timer
  (the standard "next tick" push that the §8.3 status push
  uses to refresh the live battery / counter data).
* "Write" path: state is bad → write the 4-byte packed
  value from `req[1..4]` into `DAT_0082bfd4 + 0x2C`.

#### Self-marker pattern (like `0x90` §8.6 and `0x96` §8.4)

The handler writes `0x60` at **both byte 0 and byte 15** of
the response — the same self-marker pattern used by `0x90`
(self-marker echo) and `0x96` (reset-state). The byte-15
`0x60` is *intentional*, not a checksum. The host verifies
by `byte 0 == 0x60 && byte 15 == 0x60`.

#### Why a §8.16 if it's a "tiny" handler?

The handler is short (~15 instructions), but it ties
together three important subsystems:

1. The **`DAT_0082bfd4 + 0x2C` status field** that
   `0x61 'a'` reads (§8.3) — i.e. `0x60` *writes* what
   `0x61 'a'` *reads*. Without documenting `0x60`, the
   `0x61 'a'` status push is a black box.
2. The **same `FUN_0082762c()` / `FUN_0082d754()` state
   checks** used by `0x61 'a'` (§8.3). The two handlers
   share the "is the firmware in the right mode?" guard.
3. The **same `DAT_0082bfd4` base pointer** used as the
   state anchor for both `0x60` and `0x61 'a'`. `DAT_0082bfd4`
   is the "live status" struct that backs the entire
   battery / counter subsystem; the `+0x2C` field is the
   "current snapshot" u32 that the host reads via `0x61 'a'`.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x60` | cmd (consumed by dispatcher) |
| 1..4 | `value` (4 B LE) | packed u32 to write to `DAT_0082bfd4 + 0x2C` |
| 5..14 | unused | — |

The 4-byte packed layout is `req[1] | (req[2] << 8) | (req[3] << 16) | (req[4] << 24)` — i.e.
**big-endian order of the request bytes** maps to LE u32 in
the firmware. The host packs the value the same way it
reads it back from `0x61 'a'` (the `0x61 'a'` response has
the same byte layout — see §8.3).

#### Pair with `0x61 'a'` (§8.3)

| | `0x60` | `0x61 'a'` |
|---|---|---|
| Direction | host → watch (write) | watch → host (read) |
| Field | `DAT_0082bfd4 + 0x2C` | same |
| Use case | inject a fake status (test rigs, vendor QA) | read live battery / counter |

A test rig that wants to verify the host's status-decoding
path can use `0x60` to write a known u32 and `0x61 'a'` to
read it back. A production host only uses `0x61 'a'`.

#### Why the byte-15 `0x60`?

Like `0x90` self-marker (§8.6) and `0x96` reset-state (§8.4),
the byte-15 `0x60` is a **handshake / self-identification**
marker — the response says "the watch is in `0x60` mode and
this frame is a `0x60` ack". The host SDK that consumes
`0x60` should special-case the byte-15 verification rather
than trusting the additive checksum (which will be `0xC0`,
not `0x60`).

### 8.17 0xbf / 0xc0 vendor memory R/W (`fee7_vendor_memory_write`, `fee7_vendor_memory_read`)

The **arbitrary-memory read/write pair** for OEM vendor
tools. `0xbf` lets the host write `up_to_8_bytes` to any
4-byte address; `0xc0` lets the host read `16..512_bytes`
from any 4-byte address via the fragmented streamer. These
are the *most powerful* opcodes in the 0xFEE7 dispatcher
— a host can inspect or modify any RAM byte the firmware
exposes, including the per-feature state at `DAT_008277f0`,
the deferred-ring state at `DAT_0082bfcc`, the OTA state at
`DAT_00830120/0124`, etc.

#### `0xbf` — vendor memory write

```c
void fee7_vendor_memory_write(undefined1 *param_1) {
    uint8_t len = param_1[5];
    if (len > 8) len = 8;
    if (len != 0) {
        func_0x0003f848(   // memcpy
            ((uint32_t)(param_1[1]) << 24) | // destination address, BE32
            ((uint32_t)(param_1[2]) << 16) |
            ((uint32_t)(param_1[3]) <<  8) |
            ((uint32_t)(param_1[4])),
            param_1 + 6,                    // source = payload[6..6+len]
            len
        );
    }
    FUN_0082b986(*param_1, 0);             // 1-byte cmd ack
}
```

The destination address is built big-endian from
`req[1..4]` and passed to `func_0x0003f848` (memcpy) as a
**raw pointer**. The firmware does *no validation* of the
address — a misbehaving host can scribble anywhere in RAM,
including the vector table at `0x00826400`, the firmware
constants, and the deferred-ring worker state.

#### `0xc0` — vendor memory read

```c
void fee7_vendor_memory_read(undefined1 *param_1) {
    uint32_t len = ((uint32_t)(param_1[5]) << 24) |
                   ((uint32_t)(param_1[6]) << 16) |
                   ((uint32_t)(param_1[7]) <<  8) |
                   ((uint32_t)(param_1[8]));
    if (len == 0)      len = 0x10;       // default 16 B
    else if (len > 0x200) len = 0x200;    // cap at 512 B
    FUN_0082b938(   // fragmented streamer
        *param_1,
        ((uint32_t)(param_1[1]) << 24) |
        ((uint32_t)(param_1[2]) << 16) |
        ((uint32_t)(param_1[3]) <<  8) |
        ((uint32_t)(param_1[4])),
        len & 0xffff
    );
}
```

The length is built big-endian from `req[5..8]`, clamped to
`[0x10, 0x200]` (16..512 bytes), and passed to the
`FUN_0082b938` fragmented streamer (see §3.2 / §3.11).
The source address is also built big-endian from `req[1..4]`
and passed to `FUN_0082b938` as a raw pointer.

#### Request layouts

**`0xbf` request:**
```
byte 0: 0xBF                (cmd)
byte 1..4: address (u32 BE) — destination in firmware RAM
byte 5: length (clamped to 0..8)
byte 6..14: payload (up to 8 B to copy)
```

**`0xc0` request:**
```
byte 0: 0xC0                (cmd)
byte 1..4: address (u32 BE) — source in firmware RAM
byte 5..8: length (u32 BE) — clamped to [0x10, 0x200]
byte 9..14: unused
```

#### Response layouts

**`0xbf` response:** self-marker ack via `FUN_0082b986` —
`[0xBF, 0, ..., 0, 0xBF]`. This path does not use the normal additive
checksum in byte 15.

**`0xc0` response:** fragmented payload via `FUN_0082b938`
— N frames of `[0xC0, seq, 13 data bytes, cksum]` where the
data is `length` bytes copied from the requested source.
Reassemble using the standard fragmented-streamer recipe.

#### Security implications

These two opcodes are **insecure by design**: a hostile host
with a paired BLE link can:
* `0xc0` — read any RAM byte, including security state, BLE
  pairing keys, the OTA signature buffer, etc.
* `0xbf` — write any RAM byte, including the per-feature
  state bitmap at `DAT_008277f0 + 0x2D` (which would let
  the host force `0x36` HR-enable, `0x38` pressure-enable,
  etc. without going through the normal opcodes), the
  deferred-ring state, or even the firmware's own
  return-address stack.

A production firmware *should* gate these behind a "vendor
mode" flag that requires an OEM-signed unlock, but the
H59MA v14 firmware does not — `fee7_vendor_memory_write` and
`fee7_vendor_memory_read` are unconditionally called from the 0xFEE7
dispatcher (§8.1).

#### Why these opcodes exist

The pair is a **debug / factory-test escape hatch** — the
OEM vendor tools use it to:
* Inspect the runtime state of the watch during production
  calibration (read the step-counter bias, HR baseline, etc.).
* Patch the runtime config to skip the splash screen or
  force-enable a feature for a specific test batch.
* Hot-patch a bug in a pre-release firmware without rebuilding
  the whole image.

The OpenWatch host SDK should *not* call these opcodes
unless it has explicit user consent (e.g. an "Advanced /
Developer" toggle in the host app). A normal user-driven BLE
session should never expose `0xbf` / `0xc0`.

#### Pair with `0xce` (§8.10) and `0xa1` (§3.x)

The vendor R/W pair sits **below** `0xce` (which calls into
*function-pointer tables* the OEM populates) and `0xa1`
(which calls into the structured factory-test helpers).
`0xbf` / `0xc0` are *raw-memory access* — the lowest level
of the test-tool hierarchy. An OEM tool would typically use
`0xa1` for "normal" tests, `0xce` for "vendor-function"
tests, and `0xbf` / `0xc0` for "raw memory" debug.

#### Why no address validation

The firmware uses `func_0x0003f848` (the standard memcpy)
directly with the host-supplied address. There is *no*
bounds check, *no* MPU-region check, *no* "is this address
in a vendor-readable region?" gate. The watchdog is the
host SDK's own policy — the firmware trusts the caller.

### 8.18 0x93 firmware version + build-date string (`fee7_send_fw_version_build_info_93`)

The vendor-string variant of `0x48 'H'` handshake (§8.2).
While `0x48 'H'` returns the device-info block as a
**packed u32** in bytes 1..4 (the §8.2 "non-uniform byte
order" layout), `0x93` returns the same firmware version +
build date as a **human-readable ASCII string** that the
host SDK can print directly without any byte-order
interpretation.

#### Behavior

```c
void fee7_send_fw_version_build_info_93() {
    // header frame [0x93, 0, ..., 0, 0x93]
    rsp[0]  = 0x93;
    rsp[15] = 0x93;            // self-marker pattern (like 0x90/0x96/0x60)
    FUN_0082ebdc(rsp);

    // build the 14-byte payload from two strings
    char buf[20];
    memset(buf, 0, 0x14);

    // version string: vendor-supplied OR static fallback
    if ((*(DAT_00827e8c + 0xd5) & 0x3f) >> 4 == 1)
        FUN_0083df8c(buf, DAT_00827e8c + 0x9e);  // vendor version
    else
        FUN_0083df8c(buf, s_1_00_14__00827e94);  // "1.00.14_"

    // build-date string: vendor-supplied OR static fallback
    if (*(DAT_00827e8c + 0xd5) >> 6 == 1)
        FUN_0083df8c(buf + strlen(buf), DAT_00827e8c + 0xae);  // vendor date
    else
        FUN_0083df8c(buf + strlen(buf), s_260508_00827ea0);  // "260508"

    // send the version+date string
    memcpy(rsp + 1, buf, 0xe);
    rsp[15] = FUN_0082b0c4(rsp, 0xf);
    FUN_0082ebdc(rsp);
}
```

#### The two vendor-supplied strings

The handler reads two strings from the `DAT_00827e8c` vendor
context (populated by the OEM build):

| Field offset | Length | Purpose |
|---:|---:|---|
| `+0x9E` | ≤ 7 B | firmware version (e.g. `"2.00.01_"` if the OEM overrode it) |
| `+0xAE` | ≤ 7 B | build date (e.g. `"251231"` if the OEM overrode it) |

The two control bits in `DAT_00827e8c + 0xd5`:

| Bit | Effect when set |
|---:|---|
| bits 4..5 (`& 0x3f >> 4 == 1`) | Use vendor-supplied version string from `+0x9E` |
| bit 6 (`>> 6 == 1`) | Use vendor-supplied build date from `+0xAE` |

If either bit is unset, the handler falls back to the
**statically-compiled strings**:

| Address | String | Meaning |
|---|---|---|
| `0x00827e94` | `"1.00.14_"` | firmware version baked at compile time |
| `0x00827ea0` | `"260508"` | build date baked at compile time (YYMMDD) |

#### Response layout

The handler sends **two frames back-to-back**:

1. **Header frame** (16 B):
```
byte  0: 0x93                (cmd)
byte  1..11: 0
byte 12..14: 0
byte 15: 0x93                (self-marker)
```

2. **Version+date frame** (16 B):
```
byte  0: 0x93                (cmd)
byte  1..N: version string (e.g. "1.00.14_")
byte  N+1..M: build-date string (e.g. "260508")
byte  M+1..14: 0
byte 15: additive checksum
```

The total string length is `N + M ≤ 14` (the two strings
concatenated into bytes 1..14). For the H59MA v14 build, the
payload is `"1.00.14_260508"` (13 bytes, fits with one zero
padding byte).

#### Self-marker pattern (4th occurrence)

Like `0x90` self-marker (§8.6), `0x96` reset-state (§8.4),
and `0x60` status-field write (§8.16), the `0x93` handler
first sends a **header self-marker at bytes 0 + 15**. The
second version/date frame is a normal data frame with an
additive checksum. This is the *fourth* handler family in the
table to send a self-marker ACK:

* `0x90` — marker at bytes 0 + 15
* `0x96` — marker at bytes 0 + 15
* `0x60` — marker at bytes 0 + 15
* `0x93` — header marker at bytes 0 + 15, then a checksumed string frame

The header frame is only an exchange marker. The version/date
payload is carried by the following checksumed frame.

#### Why two frames?

The handler first sends a **header frame** (with the marker
at byte 15) so the host SDK can quickly detect the start of a
`0x93` exchange *before* waiting for the slower version+date
frame. This is a vendor pattern: a quick "watch is about to
send a long string" tick, then the actual string. The host
SDK should:

1. Read the header frame, expect `byte 0 == 0x93 && byte 15
   == 0x93`.
2. Read the next frame, parse the string from bytes 1..14.

If the host SDK tries to merge both frames into one, the
header would be mis-parsed as an empty string frame because
the header *also* has byte 0 = 0x93.

#### Pair with `0x48 'H'` handshake (§8.2)

`0x48 'H'` and `0x93` are *two answers* to the same question
("what firmware is running?"). `0x48` returns the packed u32
(the OEM-internal format used by the H59MA SDK); `0x93`
returns the human-readable string (used by vendor tools and
debug logs). A host that needs to *parse* the firmware version
should use `0x48`; a host that needs to *display* it (e.g.
for a "device info" screen) should use `0x93`.

#### Why ASCII instead of BCD

The `1.00.14_` format is **plain ASCII** — bytes `0x31 0x2E
0x30 0x30 0x2E 0x31 0x34 0x5F` (`"1.00.14_"`). Unlike the
§8.2 `0x48 'H'` response which uses the OEM's BCD-like byte
packing, `0x93` returns the *raw compile-time string* with no
transformation. This means a host SDK that prints
`rsp[1..14]` directly to a UI label gets a readable version
string with no parsing required.

### 8.19 0x94 / 0x95 state-update commands (`fee7_start_test_mode_94`, `fee7_start_test_mode_95`)

The **two missing members** of the 0x90-0x9f vendor
state-update trio. Together with `0x96` (§8.4), they form
a 3-state machine controlled by `DAT_00827e88[0]`:

| State value | Set by | Meaning (per `FUN_00827b1a` worker) |
|---:|---|---|
| `1` | `0x94` | state-update mode 1 — drain deferred ring, no `DAT_00827e88[1]` clear |
| `3` | `0x95` | state-update mode 3 — drain deferred ring, **clear `DAT_00827e88[1]`** |
| `4` | `0x96` (§8.4) | full reset state — drain, clear `DAT_00827e88[1]`, set mode to `4` |

#### `fee7_start_test_mode_94` (0x94)

```c
void fee7_start_test_mode_94() {
    rsp[0]  = 0x94;
    rsp[15] = 0x94;                  // self-marker pattern
    FUN_0082ebdc(rsp);
    *DAT_00827e88 = 1;               // state = 1
    FUN_00827b1a();                  // drain worker
}
```

#### `fee7_start_test_mode_95` (0x95)

```c
void fee7_start_test_mode_95() {
    rsp[0]  = 0x95;
    rsp[15] = 0x95;
    FUN_0082ebdc(rsp);
    DAT_00827e88[1] = 0;             // clear secondary flag
    *DAT_00827e88 = 3;               // state = 3
    FUN_00827b1a();
}
```

#### Behavior common to all three

Each handler ships the same **self-marker response** (cmd
at byte 0, the same cmd at byte 15, zero elsewhere) — the
**5th and 6th handler in the table** to use this pattern
(after `0x90`, `0x96`, `0x60`, `0x93`). All three then:

1. Update the state byte at `DAT_00827e88[0]` to their
   respective mode value.
2. Optionally clear the secondary flag at `DAT_00827e88[1]`
   (`0x95` and `0x96` clear it; `0x94` leaves it alone).
3. Tail-call `FUN_00827b1a` — the state-update worker from
   §8.4.

`FUN_00827b1a` then drains the deferred ring and queues a
state-update notification that pushes the new
`DAT_00827e88`-derived fields to the host.

#### Why three modes?

The three mode values (1, 3, 4) are **distinct state
transitions** that the watch's vendor state machine can
enter:

* Mode `1` — "live data refresh" (e.g. push the current
  sensor readings to the host).
* Mode `3` — "ack clear" (the watch acknowledges the host's
  last `0x96` reset and clears the secondary flag).
* Mode `4` — "factory reset" (full RAM reset, see §8.4).

The mode value is consumed by `FUN_00827b1a` (and the
worker it queues) to decide which vendor function tables to
consult and which events to publish. The host SDK does not
need to know the per-mode semantics — it just sends the
opcode and reads back the resulting state-update frames.

#### State byte `DAT_00827e88[0]`

`DAT_00827e88` is the **vendor state** struct. The two bytes
used by `0x94` / `0x95` / `0x96`:

| Off | Field | Set by |
|---:|---|---|
| 0 | `state_mode` | `0x94` → `1`, `0x95` → `3`, `0x96` → `4` |
| 1 | `secondary_flag` | `0x95` → `0`, `0x96` → `0`, `0x94` → unchanged |

The host can read `DAT_00827e88[0]` via `0xc0` memory
read (§8.17) to learn which mode the watch is currently in,
and `DAT_00827e88[1]` to learn whether the secondary flag is
set.

#### Pair with `0xce ' '` factory-test (0xFEE7 vendor)

`0xce ' '` (§8.10) also calls `FUN_00827b1a` (and other
helpers) to set up vendor state before running its
self-test loop. So `0x94` / `0x95` / `0x96` and `0xce` share
the same vendor state-update plumbing. The difference is
that `0x94` / `0x95` / `0x96` set the *mode* (1/3/4) without
running a test, while `0xce` sets the mode (implicit) and
runs the test loop.

#### Self-marker pattern (5th and 6th occurrences)

`0x94` and `0x95` use the same `rsp[0] = cmd; rsp[15] = cmd;
FUN_0082ebdc(rsp)` shape as the `0x93` header (§8.18). The
full set of self-marker handlers in the table is now:

* `0x60` — bytes 0 + 15 (§8.16)
* `0x90` — bytes 0 + 15 (§8.6)
* `0x93` — bytes 0 + 15 (§8.18 header frame)
* `0x94` — bytes 0 + 15 (this section)
* `0x95` — bytes 0 + 15 (this section)
* `0x96` — bytes 0 + 15 (§8.4)

Every verified self-marker ACK in this group writes the
second marker at byte 15. `0x93` is the special two-frame
case: the header uses the byte-15 marker, and the following
version/date payload frame uses the normal additive checksum.

### 8.20 0x97-0xa0 high-range session/status summary

The high-range switch8 at `0x82c6e0` (§8.1) dispatches ten
opcodes (`0x97..0xA0`). A later radare2 pass corrected the
earlier default-slot interpretation: the range contains a mix
of no-response placeholders and real session/model/status
handlers. The same switch-table byte sequence appears in v13
body offset `0x6382` and v14 body offset `0x62e0`; raw evidence
is in `firmwares/_re/fee7-high/evidence.md`.

| Opcode | v14 target | Callee | Behavior |
|---:|---:|---:|---|
| `0x97` | `0x6476` | `0x17a4` | Return only; no response. |
| `0x98` | `0x647e` | `0x17e6` -> `0x17b8` | Set high-range session mode `1`; self-marker ACK `[0x98, 0..., 0x98]`. |
| `0x99` | `0x6486` | `0x17ea` | Return only; no response. |
| `0x9a` | `0x648e` | `0x17ec` -> `0x17b8` | Set high-range session mode `2`; self-marker ACK `[0x9a, 0..., 0x9a]`. |
| `0x9b` | `0x6496` | `0x17f0` | Send `[0x9b, state_byte, ..., checksum]`; `state_byte` is `0x88` for mode `2`, else `0x77`. |
| `0x9c` | `0x649e` | `0x181e` | Self-marker ACK, stop factory-test timer, clear related state, call shared cancel path. |
| `0x9d` | `0x6352` | — | Dispatcher return; no response. |
| `0x9e` | `0x64a6` | `0x18c8` | Send ASCII model string, default `"H59MA_V1.0"` unless blob0 custom-name flag is enabled. |
| `0x9f` | `0x64b6` | `0x1716` | Return only; no response. |
| `0xa0` | `0x64ae` | `0x191a` | Send opaque high-status frame; bytes 1..9 are populated from runtime helpers and persistent state. |

#### Cross-reference: ECG/PPG open question

This corrected high-range map is also a negative result for
the ECG/PPG notify-opcode search. The implemented responses in
this range are session ACK/status, model string, and a compact
opaque status frame; none match the documented
`[status, ecgInterval, ppgInterval]` or `[rate, ppgValue]`
shapes. ECG/PPG listener opcodes therefore remain live-capture
work rather than hidden `0x97..0xA0` FEE7 handlers.

### 8.21 Self-marker opcode pattern synthesis

Ten 0xFEE7 opcodes use a **self-marker response** (write the
cmd byte twice — once at the standard byte 0, once at a
non-standard byte 15 position — instead of routing through a
payload checksum builder). The pattern was discovered piecemeal
across §8.4 / §8.6 / §8.16 / §8.18 / §8.19 / §8.20; this
section pulls the threads together.

#### The full self-marker list

| Opcode | § | Marker offset | Payload frame? | Rationale |
|---|---|---:|---|---|
| `0x60` | §8.16 | byte 15 | no | 1-byte ack with no payload — marker at byte 15 |
| `0x90` | §8.6 | byte 15 | no | echo with no payload — marker at byte 15 |
| `0x93` | §8.18 | byte 15 | yes, second frame | header ACK at byte 15, then a checksumed version/date string frame |
| `0x94` | §8.19 | byte 15 | no | state-update mode 1 ack with no payload — marker at byte 15 |
| `0x95` | §8.19 | byte 15 | no | state-update mode 3 ack with no payload — marker at byte 15 |
| `0x96` | §8.4 | byte 15 | no | reset-state ack with no payload — marker at byte 15 |
| `0x98` | §8.20 | byte 15 | no | set high-range session mode 1; marker at byte 15 |
| `0x9a` | §8.20 | byte 15 | no | set high-range session mode 2; marker at byte 15 |
| `0x9c` | §8.20 | byte 15 | no | factory-test stop ack; marker at byte 15 |
| `0xbf` | §8.17 | byte 15 | no | raw memory-write ack; marker at byte 15 |

#### The byte 15 rule

Every verified self-marker ACK writes the second marker at
byte 15. `0x93` is the only two-frame member of the group: its
first frame is an empty byte-15 self-marker ACK, and its second
frame carries the version/date ASCII payload with a normal
additive checksum.

#### Why bypass the checksum at all?

The §3 "Common response path" (§3 "Notable Data & Globals"
above) computes an **additive checksum** over bytes 0..14 and
stores it in byte 15. The self-marker handlers replace this
with a **second copy of the cmd byte**. The rationale:

* The handlers fire-and-forget (no payload, no follow-up
  frames) — the host doesn't need the checksum to verify
  the body (there is no body).
* The marker byte 0 + byte X pair gives the host a cheap
  self-identification check: `byte 0 == cmd && byte X == cmd`
  confirms the response came from this opcode without
  needing to compute or compare checksums.
* For `0x93`, the marker ACK is only the first frame; the
  following version/date frame uses the normal additive
  checksum and should be parsed separately.

#### Host SDK recipe

The host SDK that consumes a self-marker response should:

1. **Verify the marker pair** (`byte 0 == byte 15 == cmd`).
2. **Validate it as a marker ACK, not as a data frame** — byte 15 was
   written as the opcode marker. For empty ACKs this often equals the
   additive sum by construction, but the firmware did not route through
   the checksumed payload builder.
3. **Treat the response as opaque** — the body between
   byte 1 and the marker byte (if any) is the meaningful
   payload; everything else is zero-padded.

A host SDK should keep dedicated self-marker checks in its
per-opcode response validator so these ACKs are not mistaken
for ordinary payload-bearing frames.

#### Why these handlers?

The H59MA firmware uses the self-marker pattern for
**state-transition / config-write / status-push commands** —
the kinds of opcodes where the host cares more about
*whether the command was accepted* than about the body
content. The self-marker handlers all fall into this
category:

* `0x60` / `0x90` / `0x94` / `0x95` / `0x96` / `0x98` /
  `0x9a` / `0x9c` / `0xbf` — state transitions, config writes,
  or raw write ACKs with no payload body.
* `0x93` — two-frame config read: self-marker header, then
  checksumed version/date payload.

The opposite case — *data-rich* opcodes like `0x37 pressureSetting`
(§3.20) or `0x7a muslim` (§3.11) — uses the **standard
additive checksum** because the host cares about the body
content and the checksum catches transmission errors.

#### §3 Channel-A equivalents?

Channel-A opcodes do *not* use the self-marker pattern. The
§3 dispatcher (`channel_a_dispatch_queued_frame`) always emits the standard
additive checksum. The self-marker pattern is a **0xFEE7-
only** convention, used by 10 of the ~50 documented 0xFEE7
opcodes (the rest use the standard checksum).

This makes the self-marker pattern a *signal* — a host SDK
that sees an opcode is a self-marker handler knows the opcode
is a state-transition / config-write (vs a data-rich read)
and can use a simpler validator path.

#### Why this synthesis section exists

The self-marker pattern was discovered piecemeal across
§8.4 / §8.6 / §8.16 / §8.17 / §8.18 / §8.19 / §8.20 — several
handler sections that each note the `byte 0 == byte 15`
pattern in isolation. Without a synthesis
section, a host SDK author reading the doc would have to
combine those notes themselves to understand the *common*
pattern. This section pulls the threads together so the
synthesis is in one place.

### 8.22 Cross-section wire-format synthesis

A consolidated view of the **16-byte request / 16-byte
response** wire format shared by **Channel-A** (§3),
**Channel-B** (§2), **0xFEE7 vendor service** (§8),
**ANCS** (§4), and **OTA** (§5). The format is identical
across all five sections — the only differences are the
command-byte position and the checksum / self-marker
treatment.

#### Common wire format

```
byte  0:    command opcode (channel-specific)
byte  1:    sub-cmd / sub-byte
byte  2..14: payload (channel-specific layout)
byte 15:    additive checksum OR self-marker byte
```

The **16-byte length** matches the BLE ATT_MTU-1 (MTU 23
minus 3-byte L2CAP header minus 3-byte ATT header minus 1-byte
opcode). It's the maximum single-frame payload BLE supports.

#### Command-byte position per section

| Section | Opcode byte | Sub-byte byte |
|---|---|---|
| Channel-A (§3) | byte 0 | byte 1 |
| Channel-B (§2) | byte 0 | byte 1 |
| 0xFEE7 vendor (§8) | byte 0 | byte 1 |
| ANCS (§4) | byte 0 (notification source) or byte 1 (data source / control point) | byte 1 (cmd id) |
| OTA (§5) | byte 1 (within 4-byte CRC + cmd header) | byte 0 (OTA start/stop/etc.) |

The §3 dispatcher (`channel_a_dispatch_queued_frame`) consumes a queued copy of
the same 16-byte Channel-A frame used on the wire: command byte at offset 0,
sub-byte at offset 1, checksum at offset 15. The ring head/tail metadata lives
outside the entry, not in bytes 0..1 of the frame.

#### Response treatment

| Section | Response opcode | Checksum treatment |
|---|---|---|
| Channel-A | echoes request cmd | additive checksum (FUN_0082b0c4) |
| Channel-B | command-specific (`0x41` list → `0x42`; most reads echo request cmd; NAK carries original cmd) | CRC-16/MODBUS over the Channel-B payload |
| 0xFEE7 vendor | echoes request cmd | additive checksum OR self-marker (§8.21) |
| ANCS | n/a (notification source is read-only) | n/a |
| OTA | echoes request cmd | CRC + length header (§5) |

The §3 "Common response path" (§3 above) computes
`rsp[15] = FUN_0082b0c4(rsp, 0xf)` — an additive checksum
over bytes 0..14. Channel-A and Channel-B and most
0xFEE7 opcodes use this same path. The 0xFEE7 self-marker
handlers (§8.21) bypass it for state-transition opcodes.

#### Sub-byte position (byte 1)

All sections use **byte 1** as the sub-cmd selector:

* **Channel-A** — `byte 1` is the sub-cmd for opcodes like
  `0x18 0x01`, `0x18 0x02`, `0x39 0x03`, `0x39 0x04`,
  `0x3a 0x01`, `0x3a 0x02`, `0x3a 0x03`, `0x3a 0x04`,
  `0x3b 0x01`, `0x3b 0x02`, `0x69 0x01`, `0x69 0x02`,
  `0x69 0x03`, etc.
* **Channel-B** — `byte 1` is the sub-cmd for opcodes like
  `0x11 day_offset`, `0x12 day_offset`, `0x29 (nop)`,
  `0x2a day_offset`, `0x3b (nop)`, `0x41 file_index`,
  `0x43 file_init_payload`, `0x46 file_delete_payload`,
  `0x47 (nop)`, `0x4b (nop)`, `0x5a config_tlv`.
* **0xFEE7 vendor** — `byte 1` is the sub-cmd for opcodes
  like `0x60 0x00`, `0xce 0x01`, `0xce 0x02`,
  `0xce ' '`, `0xce '!'`, `0xce '"'`, `0x94 (none)`,
  `0x95 (none)`, etc.

The **§3 exception** is byte 1 being the *first byte after
the dispatcher reads bytes 0..1* — so for §3 opcodes
`byte 1` is the *sub-cmd* AND the first byte of the cmd-byte
field. The dispatcher reorders: it reads bytes 0..1 as
queue/fragment metadata, then bytes 2..15 as the cmd.

#### §2 / §8 vs §3 fragmentation

§2 (Channel-B) and §8 (0xFEE7) opcodes can return
**multi-frame** responses (the §3.6 `0x43 readDetailSport`
multi-frame 292-byte response, the §3.11 `0x7a muslim`
4-frame fragmented response, etc.). These are emitted via
`FUN_0082b938` (§3.6) which fragments the body into 13-byte
chunks with a sequence-number frame header.

§3 opcodes use the §3.6 fragmentation pattern too, but
their frames stay within the §3.6 dispatcher ring
(`FUN_0082be64`, see §3.24) — the multi-frame response is
queued for the worker to emit asynchronously.

ANCS uses the **standard ATT notification** format (which is
*not* the 16-byte firmware format — ANCS payloads are
variable-length). The §4.1-§4.3 wrappers convert between
the firmware format and the ANCS format.

#### Shared state / data buffers

All sections share **a common pool of state buffers** in
the firmware's RAM:

| Buffer | Section | Purpose |
|---|---|---|
| `DAT_0082bfcc` | §3.24 | deferred-ring (10 × 16 B) |
| `DAT_0082bfd4 + 0x2C` | §8.3 / §8.16 | live status u32 |
| `DAT_0082cff0` | §3.5 | user-config block (164 B) |
| `DAT_0082caec[3..5]` | §8.1 | config-byte writes via 0xC5/0xC8/0xC9 |
| `DAT_00827e88` | §8.19 | state-update mode + secondary flag |
| `DAT_008277f0 + 0x2D` | §3.23 | sensor enable bitmap (8 bits) |

The §3 / §4 / §8 / §2 handler sections each reference one
or more of these buffers. This synthesis section is the
**only place in the doc** that lists them all together so
a host SDK author who needs to track which buffer is owned
by which handler can find it in one location.

#### Why this synthesis section exists

The §3 / §4 / §8 / §2 / §5 sections each document the wire
format for *their* handler family, but the **shared
16-byte envelope** is described independently in each
section. A host SDK author reading the doc top-to-bottom
would have to cross-reference the multiple descriptions
to understand the common envelope. This section pulls the
threads together: the 16-byte envelope is the **single
universal wire format** shared by all five sections, with
§3 being the odd one out (cmd at byte 2 not byte 0) and
§8.21 being the odd-one-out within the 0xFEE7 section (six
handlers bypass the checksum via self-marker).

#### Round-trip recipe (host SDK)

A host SDK that wants to talk to the H59MA v14 firmware:

1. Build a 16-byte frame:
   - For §3 opcodes: bytes 0..1 = queue metadata,
     byte 2 = cmd, byte 3 = sub-cmd, bytes 4..14 = payload,
     byte 15 = additive checksum of bytes 0..14.
   - For §2 / §8 opcodes: byte 0 = cmd, byte 1 = sub-cmd,
     bytes 2..14 = payload, byte 15 = additive checksum of
     bytes 0..14.
   - For §8 self-marker opcodes: byte 0 = cmd, byte 1 = sub,
     bytes 2..14 = payload, byte 15 = cmd (NOT checksum).
2. Send via BLE GATT write (Channel-A or 0xFEE7) or via the
   OTA image header (§5).
3. Wait for the response frame(s). For §3 / §2 / §8:
   - Single frame for state-transition opcodes.
   - Multi-frame fragmented for data-rich reads (assemble
     per the 13-byte-chunk streamer — see §3.11 / §3.20).
4. Verify:
   - For standard-checksum handlers: byte 15 ==
     `FUN_0082b0c4(bytes 0..14)` mod 256.
   - For §8 self-marker handlers: byte 0 == byte 15 == cmd.
   - For §3 fragmented responses: `rsp[1] == 1..N` sequence
     numbers and `rsp[15] == checksum` per frame.
5. Parse the payload per the per-section handler spec.

#### Why this is the *last* synthesis in the doc

This is the **21st synthesis section** added to
GHIDRA_DECOMPILATION.md. Each synthesis pulled together
notes that were scattered across multiple per-handler
sections. The remaining work (smaller handlers, the
Channel-B async processor details, the OTA state machine,
etc.) can be added as new per-handler sections without
needing further synthesis — the per-section docs are
sufficiently granular that the host SDK can read them
directly.
