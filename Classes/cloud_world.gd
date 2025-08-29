@tool

extends Node3D
class_name Cloud_World

@export var world_environment_path : NodePath
var world_environment

@export var texture_rect_path : NodePath
var texture_rect : TextureRect

var rect_material : ShaderMaterial

func _ready() -> void:
	texture_rect = get_node(texture_rect_path)
	world_environment = get_node(world_environment_path)
	if !world_environment.environment: 
		world_environment.environment = Environment.new()
	
	var coverage_noise := Perlin_Noise.new()
	var coverage_tex = coverage_noise.generate_2d(256, 5, 5, 125.5)
	
	var worley_noise := Worley_Noise.new()
	var worley_tex = worley_noise.generate_3d(32, 5, 5, 15)
	
	var erosion_noise := Erosion_Noise.new()
	var erosion_tex = erosion_noise.generate_3d(32, 64, 5, 5, 15)
	
	
	# Create a ShaderMaterial for the TextureRect
	var shader_code := """
	shader_type canvas_item;

	uniform sampler3D worley_tex;
	uniform float slice = 0.1;
	uniform float time = 0.0;

	void fragment() {
		vec3 uvw = vec3(UV, fract(slice + time));
		vec2 v = texture(worley_tex, uvw).rg;
		COLOR = vec4(v, 1.0, 1.0);
	}
	"""

	var shader := Shader.new()
	shader.code = shader_code

	rect_material = ShaderMaterial.new()
	rect_material.shader = shader
	rect_material.set_shader_parameter("worley_tex", erosion_tex)
	
	texture_rect.material = null
	texture_rect.texture = coverage_tex

	texture_rect.material = rect_material
	
func _process(delta: float) -> void:
	if rect_material:
		var t = float(Time.get_ticks_msec()) / 2000.0 # animate slowly
		rect_material.set_shader_parameter("time", t)
