shader_type spatial;
// World-space grid so movement speed is easy to read on flat floors.

uniform vec3 base_color : source_color = vec3(0.28, 0.3, 0.33);
uniform vec3 line_color : source_color = vec3(0.45, 0.48, 0.52);
uniform float cell_size = 2.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 coord = world_pos.xz / cell_size;
	vec2 grid = abs(fract(coord - 0.5) - 0.5) / fwidth(coord);
	float line = 1.0 - min(min(grid.x, grid.y), 1.0);
	ALBEDO = mix(base_color, line_color, line);
	ROUGHNESS = 0.9;
}
