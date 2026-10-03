extends Control

# key checker + world builder. hits whichever provider's endpoint with the
# key, using that provider's auth style, and can loop asking it to describe
# tiny objects to add to the 3D scene behind the panel.

@onready var http := $HTTPRequest
@onready var provider_select := $Panel/Margin/Rows/ProviderSelect
@onready var url_box := $Panel/Margin/Rows/UrlInput
@onready var key_box := $Panel/Margin/Rows/KeyInput
@onready var go_btn := $Panel/Margin/Rows/TestButton
@onready var status := $Panel/Margin/Rows/StatusBox/StatusLabel

@onready var ai_http := $AIRequest
@onready var build_timer := $BuildTimer
@onready var build_btn := $Panel/Margin/Rows/BuildButton
@onready var build_status := $Panel/Margin/Rows/BuildStatusLabel
@onready var spawned := $World/Spawned
@onready var world_cam := $World/Camera3D
@onready var token_slider := $Panel/Margin/Rows/TokenSlider
@onready var token_slider_label := $Panel/Margin/Rows/TokenSliderLabel

const SPINNER = ["-", "\\", "|", "/"]
var spin_i = 0
var busy = false

const PROVIDER_KEYS = ["openai", "anthropic", "minimax"]
const PROVIDERS = {
	"openai": {
		"test_url": "https://api.openai.com/v1/models",
		"build_url": "https://api.openai.com/v1/chat/completions",
		"build_model": "gpt-6-astra",
	},
	"anthropic": {
		"test_url": "https://api.anthropic.com/v1/models",
		"build_url": "https://api.anthropic.com/v1/messages",
		"build_model": "claude-opus-5",
	},
	"minimax": {
		"test_url": "https://api.minimax.io/v1/chat/completions",
		"build_url": "https://api.minimax.io/v1/chat/completions",
		"build_model": "MiniMax-M2",
	},
}
const ANTHROPIC_VERSION = "2023-06-01"
const ANTHROPIC_PREFILL = "{\"objects\":["

const MAX_LIVE_OBJECTS = 400
var building = false
var total_built = 0
var ai_busy = false
var build_provider = "openai"

func _ready():
	go_btn.pressed.connect(_go)
	http.request_completed.connect(_done)
	build_btn.pressed.connect(_toggle_building)
	build_timer.timeout.connect(_ask_ai_for_object)
	ai_http.request_completed.connect(_ai_done)
	provider_select.item_selected.connect(_on_provider_changed)
	_on_provider_changed(provider_select.selected)
	token_slider.value_changed.connect(_on_token_slider_changed)
	_on_token_slider_changed(token_slider.value)

func _on_token_slider_changed(value: float):
	token_slider_label.text = "Max tokens per request: %s" % _format_token_count(int(value))

func _format_token_count(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (n / 1000000.0)
	if n >= 1000:
		return "%.1fK" % (n / 1000.0)
	return str(n)

func _provider_key() -> String:
	return PROVIDER_KEYS[provider_select.selected]

func _on_provider_changed(index: int):
	var key = PROVIDER_KEYS[index]
	url_box.text = PROVIDERS[key]["test_url"]
	key_box.placeholder_text = "paste your %s key here" % key.capitalize()

func _process(_dt):
	if not busy:
		return
	spin_i = (spin_i + 1) % SPINNER.size()
	status.text = "testing... " + SPINNER[spin_i]

func _go():
	var url = url_box.text.strip_edges()
	var key = key_box.text.strip_edges()
	var provider = _provider_key()

	if url == "" or key == "":
		status.text = "need both a url and a key"
		return

	busy = true
	go_btn.disabled = true

	var headers: Array
	var method := HTTPClient.METHOD_GET
	var body := ""

	match provider:
		"anthropic":
			headers = ["x-api-key: " + key, "anthropic-version: " + ANTHROPIC_VERSION]
		"minimax":
			headers = ["Authorization: Bearer " + key, "Content-Type: application/json"]
			method = HTTPClient.METHOD_POST
			body = JSON.stringify({
				"model": PROVIDERS["minimax"]["build_model"],
				"messages": [{"role": "user", "content": "hi"}],
				"max_tokens": 1,
			})
		_:
			headers = ["Authorization: Bearer " + key]

	var err = http.request(url, headers, method, body)
	if err != OK:
		_finish("could not start request (err %d)" % err)

func _done(result, code, _headers, body):
	if result != HTTPRequest.RESULT_SUCCESS:
		_finish("connection problem (%d)" % result)
		return

	var ok = code >= 200 and code < 300
	var detail = _extract_message(body)
	var prefix = "OK - " if ok else "FAILED - "
	_finish(prefix + (detail if detail != "" else "HTTP %d" % code))

func _extract_message(body: PackedByteArray) -> String:
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""
	if parsed.has("message"):
		return String(parsed["message"])
	if parsed.has("error") and typeof(parsed["error"]) == TYPE_DICTIONARY:
		return String(parsed["error"].get("message", ""))
	if parsed.has("base_resp") and typeof(parsed["base_resp"]) == TYPE_DICTIONARY:
		return String(parsed["base_resp"].get("status_msg", ""))
	return ""

func _finish(msg):
	busy = false
	go_btn.disabled = false
	status.text = msg

func _toggle_building():
	if building:
		building = false
		build_timer.stop()
		build_btn.text = "Start Building World (uses key above)"
		build_status.text = "world builder stopped. %d objects built." % total_built
		return

	var key = key_box.text.strip_edges()
	if key == "":
		build_status.text = "paste a key above first"
		return

	building = true
	build_provider = _provider_key()
	build_btn.text = "Stop Building World"
	build_status.text = "starting..."
	_ask_ai_for_object()
	build_timer.start()

func _ask_ai_for_object():
	if not building or ai_busy:
		return

	var key = key_box.text.strip_edges()
	if key == "":
		_toggle_building()
		return

	ai_busy = true
	build_status.text = "asking AI for object %d..." % (total_built + 1)

	var sys_prompt = "You generate one small detailed structure for a procedural 3D world, built out of 1 to 6 primitive shapes placed close together (e.g. a hut = a box body plus a cone roof on top; a lamp = a thin cylinder pole plus a sphere on top; a tree = a cylinder trunk plus a sphere or cone for leaves). Respond with ONLY compact JSON, no prose, no markdown fences, in this exact shape: {\"objects\":[{\"shape\":\"box|sphere|cylinder|cone\",\"color\":[r,g,b],\"scale\":s,\"pos\":[dx,dy,dz],\"rot_y\":deg}, ...]} where r,g,b are 0-1 floats, s is 0.2-2.0, dx/dy/dz are small offsets in meters (-2 to 2) from the structure's anchor point so the pieces sit together correctly, and rot_y is a rotation in degrees (0-360, optional, default 0). Use 1 object for something simple, up to 6 for something elaborate."
	var user_prompt = "Generate the next structure to add to the world. Structure #%d. Feel free to be ambitious and use multiple pieces." % (total_built + 1)

	var cfg = PROVIDERS[build_provider]
	var headers: Array
	var body: Dictionary
	var token_budget = int(token_slider.value)

	match build_provider:
		"anthropic":
			# anthropic has no JSON-mode flag - force it by prefilling the
			# assistant turn so it can only continue valid JSON. the reply
			# then needs this prefix glued back onto the front.
			headers = ["x-api-key: " + key, "anthropic-version: " + ANTHROPIC_VERSION, "Content-Type: application/json"]
			body = {
				"model": cfg["build_model"],
				"max_tokens": token_budget,
				"system": sys_prompt,
				"messages": [
					{"role": "user", "content": user_prompt},
					{"role": "assistant", "content": ANTHROPIC_PREFILL},
				],
			}
		"minimax":
			headers = ["Authorization: Bearer " + key, "Content-Type: application/json"]
			body = {
				"model": cfg["build_model"],
				"max_tokens": token_budget,
				"response_format": {"type": "json_object"},
				"messages": [
					{"role": "system", "content": sys_prompt},
					{"role": "user", "content": user_prompt},
				],
			}
		_:
			headers = ["Authorization: Bearer " + key, "Content-Type: application/json"]
			body = {
				"model": cfg["build_model"],
				"reasoning_effort": "low",
				"max_completion_tokens": token_budget,
				"response_format": {"type": "json_object"},
				"messages": [
					{"role": "system", "content": sys_prompt},
					{"role": "user", "content": user_prompt},
				],
			}

	var err = ai_http.request(cfg["build_url"], headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		ai_busy = false
		build_status.text = "could not reach %s (err %d)" % [build_provider, err]

func _ai_done(result, code, _headers, body):
	ai_busy = false

	if result != HTTPRequest.RESULT_SUCCESS:
		build_status.text = "connection problem (%d), will retry" % result
		return

	if code < 200 or code >= 300:
		var msg = _extract_message(body)
		build_status.text = "%s error: %s" % [build_provider, (msg if msg != "" else "HTTP %d" % code)]
		if code == 401 or code == 403:
			_toggle_building()
		return

	var content = _extract_build_content(body)
	if content == "":
		build_status.text = "unexpected response from " + build_provider
		return

	var parts = _parse_object_specs(content)
	if parts == null or parts.is_empty():
		var snippet = content.strip_edges().left(60)
		build_status.text = "AI reply wasn't valid JSON, skipping: " + snippet
		return

	_spawn_cluster(parts)
	build_status.text = "built %d structures (%d pieces total) so far" % [total_built, spawned.get_child_count()]

func _extract_build_content(body: PackedByteArray) -> String:
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""

	if build_provider == "anthropic":
		if not parsed.has("content") or typeof(parsed["content"]) != TYPE_ARRAY or parsed["content"].is_empty():
			return ""
		# glue the prefill (see _ask_ai_for_object) back onto the front
		return ANTHROPIC_PREFILL + String(parsed["content"][0].get("text", ""))

	if not parsed.has("choices") or typeof(parsed["choices"]) != TYPE_ARRAY or parsed["choices"].is_empty():
		return ""
	return String(parsed["choices"][0]["message"]["content"])

func _parse_object_specs(content: String):
	var cleaned = content.strip_edges()
	cleaned = cleaned.replace("```json", "").replace("```", "")

	# reasoning models (MiniMax-M2 in particular) prepend a <think>...</think>
	# block before the actual JSON even in JSON mode - strip it out.
	var think_re = RegEx.new()
	think_re.compile("(?s)<think>.*?</think>")
	cleaned = think_re.sub(cleaned, "", true)
	cleaned = cleaned.strip_edges()

	var parsed = JSON.parse_string(cleaned)
	if parsed == null:
		# fallback: grab whatever is between the first { and the last }
		var start = cleaned.find("{")
		var end = cleaned.rfind("}")
		if start != -1 and end > start:
			parsed = JSON.parse_string(cleaned.substr(start, end - start + 1))

	if typeof(parsed) != TYPE_DICTIONARY:
		return null

	var objs = parsed.get("objects", null)
	if typeof(objs) != TYPE_ARRAY or objs.is_empty():
		# backwards compatible with a single bare object (no "objects" wrapper)
		if parsed.has("shape"):
			return [parsed]
		return null

	return objs.slice(0, 6)

func _spawn_cluster(specs: Array):
	# one shared anchor per structure - each piece in the cluster is placed
	# relative to it via its own "pos" offset, so multi-piece replies form
	# one coherent structure instead of landing in unrelated grid cells.
	var i = total_built
	var gx = i % 8
	var gz = i / 8
	var anchor = Vector3((gx - 3.5) * 3.0, 0.0, -gz * 3.0 - 3.0)

	for spec in specs:
		if typeof(spec) != TYPE_DICTIONARY:
			continue
		_spawn_piece(spec, anchor)

	total_built += 1

	var pull_back = clampf(total_built * 0.06, 0.0, 30.0)
	world_cam.position = Vector3(0, 2.2 + pull_back, 4.5 + pull_back * 1.9)

	while spawned.get_child_count() > MAX_LIVE_OBJECTS:
		spawned.get_child(0).queue_free()

func _spawn_piece(spec: Dictionary, anchor: Vector3):
	var mesh: Mesh
	match String(spec.get("shape", "box")):
		"sphere":
			var m = SphereMesh.new()
			m.radius = 0.5
			m.height = 1.0
			mesh = m
		"cylinder":
			var m = CylinderMesh.new()
			m.top_radius = 0.4
			m.bottom_radius = 0.4
			m.height = 1.0
			mesh = m
		"cone":
			var m = CylinderMesh.new()
			m.top_radius = 0.0
			m.bottom_radius = 0.4
			m.height = 1.0
			mesh = m
		_:
			mesh = BoxMesh.new()

	var color_arr = spec.get("color", [0.5, 0.5, 0.5])
	var color = Color(0.5, 0.5, 0.5)
	if typeof(color_arr) == TYPE_ARRAY and color_arr.size() >= 3:
		color = Color(clampf(float(color_arr[0]), 0.0, 1.0), clampf(float(color_arr[1]), 0.0, 1.0), clampf(float(color_arr[2]), 0.0, 1.0))

	var scale = clampf(float(spec.get("scale", 1.0)), 0.2, 2.0)

	var pos_arr = spec.get("pos", [0.0, 0.0, 0.0])
	var offset = Vector3.ZERO
	if typeof(pos_arr) == TYPE_ARRAY and pos_arr.size() >= 3:
		offset = Vector3(clampf(float(pos_arr[0]), -2.0, 2.0), clampf(float(pos_arr[1]), -2.0, 2.0), clampf(float(pos_arr[2]), -2.0, 2.0))

	var rot_y = fmod(float(spec.get("rot_y", 0.0)), 360.0)

	var mat = StandardMaterial3D.new()
	mat.albedo_color = color

	var inst = MeshInstance3D.new()
	inst.mesh = mesh
	inst.set_surface_override_material(0, mat)
	inst.scale = Vector3.ONE * scale
	inst.rotation.y = deg_to_rad(rot_y)
	inst.position = anchor + offset + Vector3(0, scale * 0.5, 0)

	spawned.add_child(inst)
