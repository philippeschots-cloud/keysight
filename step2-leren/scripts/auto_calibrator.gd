class_name AutoCalibrator
extends RefCounted
## Automatische kalibratie: je drukt met het gele bolletje van een controller
## een paar echte toetsen in. Via MIDI weten we precies wélke toets dat was,
## dus elk paar (toets, positie van het bolletje) is een meetpunt. Een
## kleinste-kwadratenlijn door die punten legt het virtuele klavier precies
## over de 88 echte toetsen, inclusief de breedte (schaal) van jouw piano.

const DEPTH_WHITE := 0.020   # m: bolletje drukt ~2 cm achter de voorrand van een witte toets
const DEPTH_BLACK := 0.075   # m: idem zwarte toets (die begint 5,5 cm naar achteren)
const BALL_BELOW_TOP := 0.004   # m: midden bolletje t.o.v. bovenkant toets in rust (toets is ingedrukt)
const MAX_RESIDUAL := 0.020
const MIN_SPAN := 0.30       # m: punten moeten minstens zo ver uit elkaar liggen
const MAX_SCALE_DEV := 0.05  # max 5% afwijking van 23,5 mm per witte toets
const DEBOUNCE := 0.40       # s
const CHORD_REJECT := 0.08   # s: twee aanslagen zo kort na elkaar = onduidelijk

var samples: Array = []      # [{note, p: Vector3, msec}]
var last_fit := {}
var rejected := 0


func reset() -> void:
	samples.clear()
	last_fit = {}
	rejected = 0


## Voegt een meetpunt toe. Geeft een korte uitleg terug.
func add_sample(note: int, p: Vector3) -> String:
	var now := Time.get_ticks_msec()
	if not samples.is_empty():
		var last: Dictionary = samples[-1]
		var dt: float = (now - last["msec"]) / 1000.0
		if dt < CHORD_REJECT and last["note"] != note:
			samples.pop_back()
			rejected += 1
			return "Twee toetsen tegelijk: beide punten genegeerd. Druk één toets per keer."
		if dt < DEBOUNCE and last["note"] == note:
			return ""
	# Zelfde toets opnieuw: vervang het oude punt.
	for i in range(samples.size() - 1, -1, -1):
		if samples[i]["note"] == note:
			samples.remove_at(i)
	# Ver van de huidige lijn (bv. elleboog op de toetsen)? Dan negeren.
	if last_fit.get("ok", false):
		var pred: Vector3 = predict(note)
		if pred.distance_to(p) > 0.15:
			rejected += 1
			return "Punt %s ligt %.0f cm naast de verwachting en is genegeerd." % [
				MidiMonitor.note_name(note), pred.distance_to(p) * 100.0]
	samples.append({"note": note, "p": p, "msec": now})
	last_fit = fit()
	return status_text()


func status_text() -> String:
	var n := samples.size()
	if n == 0:
		return "Druk met het gele bolletje op een witte toets helemaal links, vlak bij de voorrand."
	if not last_fit.get("ok", false):
		return "%d punt(en). %s" % [n, last_fit.get("why", "Druk nog een toets, ver van de vorige.")]
	return "%d punten, passing %.1f mm, breedte %.1f cm (schaal %.3f). Nog een paar toetsen verspreid is nauwkeuriger; trekker = klaar." % [
		n, last_fit["rms"] * 1000.0, last_fit["width"] * 100.0, last_fit["scale"]]


## Voorspelde positie van het bolletje voor een toets (volgens de huidige fit).
func predict(note: int) -> Vector3:
	if not last_fit.get("ok", false):
		return Vector3.ZERO
	var kx := PianoKeyboard.key_center_x(note)
	var front: Vector3 = last_fit["left"] + last_fit["d"] * kx
	var depth := DEPTH_BLACK if PianoKeyboard.is_black(note) else DEPTH_WHITE
	return front - last_fit["z"] * depth + Vector3.UP * (PianoKeyboard.key_top_y(note) - BALL_BELOW_TOP)


static func _line_fit(xs: Array[float], ps: Array[Vector3]) -> Array:
	var n := xs.size()
	var mx := 0.0
	var mp := Vector3.ZERO
	for i in n:
		mx += xs[i]
		mp += ps[i]
	mx /= n
	mp /= n
	var sxx := 0.0
	var sxp := Vector3.ZERO
	for i in n:
		sxx += (xs[i] - mx) * (xs[i] - mx)
		sxp += (ps[i] - mp) * (xs[i] - mx)
	if sxx < 1e-9:
		return []
	var d := sxp / sxx
	return [mp - d * mx, d]   # p(x) = a + d*x


func fit() -> Dictionary:
	var use := samples.duplicate()
	var dropped := 0
	while true:
		var r := _fit_once(use)
		if not r.get("ok_shape", false):
			return r
		# Uitschieters verwijderen (alleen als er genoeg punten zijn).
		if r["max_res"] > MAX_RESIDUAL and use.size() >= 4:
			use.remove_at(r["worst"])
			dropped += 1
			continue
		r["dropped"] = dropped
		var ok := true
		var why := ""
		if r["span"] < MIN_SPAN:
			ok = false
			why = "Punten liggen te dicht bij elkaar (%.0f cm). Druk ook een toets ver aan de andere kant." % (r["span"] * 100.0)
		elif absf(r["scale"] - 1.0) > MAX_SCALE_DEV:
			ok = false
			why = "Breedte klopt niet (schaal %.2f). Druk precies met het gele bolletje, één toets per keer." % r["scale"]
		elif r["max_res"] > MAX_RESIDUAL:
			ok = false
			why = "Punten passen slecht op één lijn (%.0f mm). Druk nog wat toetsen." % (r["max_res"] * 1000.0)
		r["ok"] = ok
		r["why"] = why
		return r
	return {}


func _fit_once(use: Array) -> Dictionary:
	var notes_seen := {}
	for s in use:
		notes_seen[s["note"]] = true
	if notes_seen.size() < 2:
		return {"ok": false, "ok_shape": false, "why": "Druk nog een toets, ver van de vorige."}
	var xs: Array[float] = []
	var ps: Array[Vector3] = []
	for s in use:
		xs.append(PianoKeyboard.key_center_x(s["note"]))
		ps.append(s["p"])
	var l := _line_fit(xs, ps)
	if l.is_empty():
		return {"ok": false, "ok_shape": false, "why": "Druk nog een toets, ver van de vorige."}
	var d: Vector3 = l[1]
	var dh := Vector3(d.x, 0, d.z)
	var scale := dh.length()
	if scale < 1e-4:
		return {"ok": false, "ok_shape": false, "why": "Kan geen richting bepalen."}
	var xdir := dh / scale
	var zdir := xdir.cross(Vector3.UP).normalized()   # naar de speler toe
	# Elk punt verschuiven naar de voorrand en naar de onderkant van het klavier.
	var qs: Array[Vector3] = []
	for i in use.size():
		var note: int = use[i]["note"]
		var depth := DEPTH_BLACK if PianoKeyboard.is_black(note) else DEPTH_WHITE
		var q: Vector3 = ps[i] + zdir * depth
		q.y = ps[i].y + BALL_BELOW_TOP - PianoKeyboard.key_top_y(note)
		qs.append(q)
	var l2 := _line_fit(xs, qs)
	var a: Vector3 = l2[0]
	var d2: Vector3 = l2[1]
	# Horizontaal houden: hoogte = gemiddelde.
	var my := 0.0
	for q in qs:
		my += q.y
	my /= qs.size()
	var d2h := Vector3(d2.x, 0, d2.z)
	var x_min := xs.min() as float
	var x_max := xs.max() as float
	var mx := 0.0
	for x in xs:
		mx += x
	mx /= xs.size()
	# Lijn door het gemiddelde punt met horizontale richting.
	var mid_q := Vector3.ZERO
	for q in qs:
		mid_q += q
	mid_q /= qs.size()
	var left := Vector3(mid_q.x, my, mid_q.z) - d2h * mx
	# Residuen t.o.v. de horizontale lijn.
	var max_res := 0.0
	var worst := 0
	var ss := 0.0
	for i in qs.size():
		var pred := left + d2h * xs[i]
		var res := pred.distance_to(Vector3(qs[i].x, qs[i].y, qs[i].z))
		ss += res * res
		if res > max_res:
			max_res = res
			worst = i
	var width := PianoKeyboard.nominal_width() * d2h.length()
	return {
		"ok_shape": true, "left": left, "d": d2h, "z": zdir,
		"right": left + d2h * PianoKeyboard.nominal_width(),
		"scale": d2h.length(), "width": width,
		"rms": sqrt(ss / qs.size()), "max_res": max_res, "worst": worst,
		"span": (x_max - x_min) * d2h.length(), "n": use.size(),
	}
