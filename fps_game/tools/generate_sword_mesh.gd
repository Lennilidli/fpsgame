extends SceneTree
## Generates the longsword blade mesh (res://assets/sword/blade_mesh.tres).
## Run: godot --headless --script res://tools/generate_sword_mesh.gd
##
## The blade runs along +Y from BASE to TIP (matching MeleeCombat's blade hitbox), with a
## diamond cross-section: sharp edges left/right and a centre ridge front/back.

const BASE := 0.105
const TIP := 0.955
const RINGS := 16


func _initialize() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1) # flat shading: crisp edges and ridge
	var rings: Array = []
	for i in RINGS + 1:
		var t := float(i) / RINGS
		var y := lerpf(BASE, TIP, t)
		rings.append(_ring(y, _half_width(t), _half_thickness(t)))
	for i in RINGS:
		var a: Array = rings[i]
		var b: Array = rings[i + 1]
		for k in 4:
			var k2 := (k + 1) % 4
			_quad(st, a[k], a[k2], b[k2], b[k])
	# Cap the base (hidden by the guard, but keeps the mesh closed).
	var base: Array = rings[0]
	_tri(st, base[0], base[2], base[1])
	_tri(st, base[0], base[3], base[2])
	st.generate_normals()
	st.generate_tangents()
	var mesh := st.commit()
	var err := ResourceSaver.save(mesh, "res://assets/sword/blade_mesh.tres")
	print("blade mesh saved: ", err == OK)
	quit()


## Edge-to-edge half width: slight taper, then a smooth point over the last 25%.
func _half_width(t: float) -> float:
	var w := lerpf(0.026, 0.019, t)
	if t > 0.75:
		w *= sqrt(maxf(1.0 - (t - 0.75) / 0.25, 0.0))
	return maxf(w, 0.0004)


func _half_thickness(t: float) -> float:
	return lerpf(0.0055, 0.0025, t) * (1.0 if t < 0.97 else 0.4)


## Right edge, front ridge, left edge, back ridge.
func _ring(y: float, w: float, th: float) -> Array:
	return [Vector3(w, y, 0.0), Vector3(0.0, y, -th), Vector3(-w, y, 0.0), Vector3(0.0, y, th)]


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_tri(st, a, b, c)
	_tri(st, a, c, d)


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	for v in [a, c, b]:
		st.set_uv(Vector2(v.x * 8.0 + 0.5, v.y * 2.0))
		st.add_vertex(v)
