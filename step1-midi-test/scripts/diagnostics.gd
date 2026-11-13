class_name Diagnostics
extends RefCounted
## Verzamelt systeeminformatie die we nodig hebben om stap 1 te beoordelen:
## platform, OpenXR/passthrough, ALSA-geluidskaarten en USB-apparaten.
## Alles wordt gelezen via /proc en /sys, zodat er geen externe tools
## (lsusb, amidi) nodig zijn binnen de Steam Linux Runtime-container.

const YAMAHA_VENDOR_ID := "0499"


static func platform_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var v := Engine.get_version_info()
	out.append("Godot %s  (%s)" % [v.string, Engine.get_architecture_name()])
	out.append("OS: %s / %s %s" % [OS.get_name(), OS.get_distribution_name(), OS.get_version()])
	out.append("Executable: %s" % OS.get_executable_path())
	out.append("user://  = %s" % ProjectSettings.globalize_path("user://"))
	out.append("Geluidsdriver: %s (ALSA-MIDI vereist ALSA of PulseAudio)" % AudioServer.get_driver_name())
	return out


static func xr_lines(xr: XRInterface) -> PackedStringArray:
	var out := PackedStringArray()
	if xr == null:
		out.append("OpenXR: interface niet gevonden")
		return out
	out.append("OpenXR geinitialiseerd: %s" % xr.is_initialized())
	if not xr.is_initialized():
		return out
	var info := xr.get_system_info()
	for k in info.keys():
		out.append("  %s: %s" % [k, info[k]])
	var modes: Array = xr.get_supported_environment_blend_modes()
	var names := PackedStringArray()
	for m in modes:
		names.append(blend_mode_name(int(m)))
	out.append("Blend modes: %s" % ", ".join(names))
	out.append("ALPHA_BLEND (passthrough) beschikbaar: %s" % (XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in modes))
	out.append("is_passthrough_supported(): %s" % xr.is_passthrough_supported())
	if xr is OpenXRInterface:
		var oxr := xr as OpenXRInterface
		out.append("Refresh rate: %.0f Hz (beschikbaar: %s)" % [oxr.display_refresh_rate, oxr.get_available_display_refresh_rates()])
		out.append("Hand tracking ondersteund: %s" % oxr.is_hand_tracking_supported())
	return out


static func blend_mode_name(m: int) -> String:
	match m:
		XRInterface.XR_ENV_BLEND_MODE_OPAQUE:
			return "OPAQUE"
		XRInterface.XR_ENV_BLEND_MODE_ADDITIVE:
			return "ADDITIVE"
		XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND:
			return "ALPHA_BLEND"
	return "?%d" % m


static func _read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	# /proc- en /sys-bestanden hebben lengte 0, dus regel per regel lezen.
	var s := ""
	while not f.eof_reached():
		s += f.get_line() + "\n"
	return s.strip_edges()


static func alsa_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var cards := _read_text("/proc/asound/cards")
	out.append("/proc/asound/cards:")
	if cards == "":
		out.append("  (niet leesbaar of leeg)")
	else:
		for l in cards.split("\n"):
			out.append("  " + l)
	var d := DirAccess.open("/dev/snd")
	if d == null:
		out.append("/dev/snd: NIET toegankelijk (container?)")
	else:
		var midi_nodes := PackedStringArray()
		for f in d.get_files():
			if f.begins_with("midi") or f.begins_with("seq"):
				midi_nodes.append(f)
		out.append("/dev/snd midi/seq-nodes: %s" % (", ".join(midi_nodes) if midi_nodes.size() > 0 else "GEEN"))
	return out


## Lijst van USB-apparaten. Markeert Yamaha en full-speed (12 Mbit/s)
## apparaten, omdat full-speed op de directe poort van de Frame problemen
## kan geven (zie SteamOS issue #2846).
static func usb_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var base := "/sys/bus/usb/devices"
	var d := DirAccess.open(base)
	if d == null:
		out.append("USB: /sys/bus/usb/devices niet leesbaar")
		return out
	var found_yamaha := false
	for dev in d.get_directories():
		if dev.contains(":"):
			continue   # interfaces overslaan, alleen apparaten
		var p := base + "/" + dev
		var vid := _read_text(p + "/idVendor")
		if vid == "":
			continue
		var pid := _read_text(p + "/idProduct")
		var product := _read_text(p + "/product")
		var maker := _read_text(p + "/manufacturer")
		var speed := _read_text(p + "/speed")
		var tags := ""
		if vid == YAMAHA_VENDOR_ID:
			tags += "  <== YAMAHA"
			found_yamaha = true
		if speed == "12":
			tags += "  [full-speed]"
		out.append("  %s %s:%s %s %s (%s Mbit/s)%s" % [dev, vid, pid, maker, product, speed, tags])
	out.insert(0, "USB-apparaten (Yamaha gevonden: %s):" % found_yamaha)
	return out
