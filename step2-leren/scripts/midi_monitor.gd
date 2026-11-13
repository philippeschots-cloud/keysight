class_name MidiMonitor
extends Node
## Opent alle MIDI-ingangen, vertaalt Godot-MIDI-events naar eenvoudige
## signalen en houdt statistieken bij voor de test.
##
## Hotplug: Godot scant MIDI-apparaten alleen bij open_midi_inputs(). Zolang
## er geen apparaat is, scannen we daarom elke paar seconden opnieuw, zodat je
## de piano ook kunt aansluiten nadat de app al draait.

signal note_on(note: int, velocity: int, channel: int)
signal note_off(note: int, channel: int)
signal control_change(controller: int, value: int, channel: int)
signal devices_changed(devices: PackedStringArray)
signal raw_event(text: String)

const RESCAN_INTERVAL := 3.0

var devices := PackedStringArray()
var held := {}                 # noot -> velocity
var total_note_ons := 0
var total_note_offs := 0
var total_events := 0
var max_polyphony := 0
var orphan_note_offs := 0      # note-off zonder voorafgaande note-on
var sustain := 0               # CC64 (0..127, Clavinova stuurt half-pedaal)
var sostenuto := 0             # CC66
var soft := 0                  # CC67
var velocity_min := 128
var velocity_max := -1
var last_event_msec := 0
var other_messages := {}       # naam -> aantal (clock, active sensing, ...)

var _rescan_timer := 0.0
var _opened := false


func _ready() -> void:
	rescan()


## Godot laadt libasound (nodig voor ALSA-MIDI) alleen mee met de ALSA- of
## PulseAudio-geluidsdriver. Met de Dummy-driver (bv. --headless) crasht
## open_midi_inputs(), dus dan slaan we MIDI over.
static func midi_backend_ok() -> bool:
	if OS.get_name() != "Linux":
		return true
	var drv := AudioServer.get_driver_name()
	return drv == "ALSA" or drv == "PulseAudio"


func rescan() -> void:
	if not midi_backend_ok():
		raw_event.emit("[fout] geluidsdriver '%s': MIDI uitgeschakeld. Start met --audio-driver ALSA" % AudioServer.get_driver_name())
		set_process(false)
		return
	# Alleen sluiten als we eerder geopend hebben: close zonder open kan
	# crashen in Godot 4.6 (gezien in headless-modus).
	if _opened:
		OS.close_midi_inputs()
	OS.open_midi_inputs()
	_opened = true
	var now := OS.get_connected_midi_inputs()
	if now != devices:
		devices = now
		devices_changed.emit(devices)
	raw_event.emit("[scan] %d MIDI-ingang(en): %s" % [devices.size(), ", ".join(devices)])


## Godot blijft een losgekoppeld ALSA-apparaat uitlezen en spamt dan
## "snd_rawmidi_read error". Daarom elke paar seconden kijken of er nog een
## USB-geluidskaart is; zo niet, de ingangen sluiten en opnieuw gaan zoeken.
var _gone_timer := 0.0


func _usb_midi_present() -> bool:
	if OS.get_name() != "Linux":
		return true
	var f := FileAccess.open("/proc/asound/cards", FileAccess.READ)
	if f == null:
		return true
	var txt := f.get_as_text()
	return txt.contains("USB")


func _process(delta: float) -> void:
	if not devices.is_empty():
		_gone_timer += delta
		if _gone_timer >= RESCAN_INTERVAL:
			_gone_timer = 0.0
			if not _usb_midi_present():
				OS.close_midi_inputs()
				_opened = false
				devices = PackedStringArray()
				devices_changed.emit(devices)
				raw_event.emit("[scan] MIDI-apparaat losgekoppeld; zoekt opnieuw")
		return
	if devices.is_empty():
		_rescan_timer += delta
		if _rescan_timer >= RESCAN_INTERVAL:
			_rescan_timer = 0.0
			rescan()


func reset_stats() -> void:
	total_note_ons = 0
	total_note_offs = 0
	total_events = 0
	max_polyphony = held.size()
	orphan_note_offs = 0
	velocity_min = 128
	velocity_max = -1
	other_messages.clear()


func _input(event: InputEvent) -> void:
	if not event is InputEventMIDI:
		return
	var e := event as InputEventMIDI
	total_events += 1
	last_event_msec = Time.get_ticks_msec()
	match e.message:
		MIDI_MESSAGE_NOTE_ON:
			# Veel toetsenborden sturen "note on met velocity 0" als note-off.
			if e.velocity == 0:
				_handle_off(e.pitch, e.channel)
			else:
				_handle_on(e.pitch, e.velocity, e.channel)
		MIDI_MESSAGE_NOTE_OFF:
			_handle_off(e.pitch, e.channel)
		MIDI_MESSAGE_CONTROL_CHANGE:
			match e.controller_number:
				64:
					sustain = e.controller_value
				66:
					sostenuto = e.controller_value
				67:
					soft = e.controller_value
			control_change.emit(e.controller_number, e.controller_value, e.channel)
			raw_event.emit("CC%-3d = %3d   kan %d" % [e.controller_number, e.controller_value, e.channel + 1])
		_:
			var n := _message_name(e.message)
			other_messages[n] = int(other_messages.get(n, 0)) + 1
			# Klok/active sensing niet in het log spammen.
			if e.message != MIDI_MESSAGE_TIMING_CLOCK and e.message != MIDI_MESSAGE_ACTIVE_SENSING:
				raw_event.emit("%s  kan %d" % [n, e.channel + 1])


func _handle_on(note: int, velocity: int, channel: int) -> void:
	total_note_ons += 1
	held[note] = velocity
	max_polyphony = maxi(max_polyphony, held.size())
	velocity_min = mini(velocity_min, velocity)
	velocity_max = maxi(velocity_max, velocity)
	note_on.emit(note, velocity, channel)
	raw_event.emit("AAN  %-4s (%3d)  vel %3d  kan %d" % [note_name(note), note, velocity, channel + 1])


func _handle_off(note: int, channel: int) -> void:
	total_note_offs += 1
	if not held.has(note):
		orphan_note_offs += 1
	held.erase(note)
	note_off.emit(note, channel)
	raw_event.emit("UIT  %-4s (%3d)            kan %d" % [note_name(note), note, channel + 1])


static func note_name(note: int) -> String:
	const NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
	return "%s%d" % [NAMES[note % 12], floori(note / 12.0) - 1]


static func _message_name(m: int) -> String:
	match m:
		MIDI_MESSAGE_AFTERTOUCH:
			return "Aftertouch"
		MIDI_MESSAGE_PROGRAM_CHANGE:
			return "ProgramChange"
		MIDI_MESSAGE_CHANNEL_PRESSURE:
			return "ChannelPressure"
		MIDI_MESSAGE_PITCH_BEND:
			return "PitchBend"
		MIDI_MESSAGE_SYSTEM_EXCLUSIVE:
			return "SysEx"
		MIDI_MESSAGE_TIMING_CLOCK:
			return "Clock"
		MIDI_MESSAGE_ACTIVE_SENSING:
			return "ActiveSensing"
		MIDI_MESSAGE_START:
			return "Start"
		MIDI_MESSAGE_STOP:
			return "Stop"
	return "Msg%d" % m
