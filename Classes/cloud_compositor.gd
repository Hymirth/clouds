@tool
class_name Cloud_Compositor
extends CompositorEffect

@export_group("scales")
@export_range(1, 100000, 1) var cloud_scale = 5000.0;
@export_range(1, 10000, 1) var erosion_scale = 100.0;
@export_range(0, 10000, 1) var loop_time = 100.0

@export_group("quality knobs")
@export var main_points : float = 100;
@export var optical_depth_points : float = 10;
@export var optical_depth_step_exponent : float = 0.7;
@export var optical_depth_erosion_coefficient : float = 0.5;
@export var optical_depth_look_distance : float = 100.0;

@export_group("artefact fixes") 
@export var max_step_coeff : float = 25.0;

@export_group("density") 
@export var erosion_exponent : float = 2.0;
@export var cloud_density : float = 0.2;
@export var uniform_coverage : float = 0.0;
@export var perlin_worley_blend_exponent : float = 0.2;
@export var top_shape_scale : float = 4.5;
@export var bottom_shape_scale : float = 5.5;
@export var peak : float = 0.15;

@export_group("colour + misc") 
@export var cloud_absp := Vector3(0.01, 0.01, 0.01);
@export var cloud_scat := Vector3(1.0, 1.0, 1.0);
@export var  forward_scatter : float = 0.85;
@export var sheer_direction := Vector3(1.0, 0.0, 0.0).normalized();
@export var  sheer_speed : float = 4.0;

var shader 			: RID
var pipeline 		: RID
var uniform_set 	: RID
var matrix_set		: RID
var matrix_buffer	: RID
var tunable_buffer	: RID
var rd 				: RenderingDevice

var coverage_tex	: Texture2DRD
var top_shape_tex	: Texture2DRD
var bottom_shape_tex: Texture2DRD
var erosion_tex 	: Texture3DRD

var data

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	rd = RenderingServer.get_rendering_device()
	
	var file = load("res://shaders/cloud_shader.glsl")
	var initial_spirv = file.get_spirv()
	shader = rd.shader_create_from_spirv(initial_spirv)
	pipeline = rd.compute_pipeline_create(shader)
	
	var perlin_noise = Perlin_Noise.new()
	var perlin_noise2 = Perlin_Noise.new()
	var perlin_noise3 = Perlin_Noise.new()
	coverage_tex = perlin_noise.generate_2d(256, 5, 5, 51)
	top_shape_tex = perlin_noise2.generate_2d(128, 3, 4, 120)
	bottom_shape_tex = perlin_noise3.generate_2d(128, 2, 4, -55120)
	
	
	var erosion_noise = Erosion_Noise.new()#Worley_Noise.new()
	erosion_tex = erosion_noise.generate_3d(128, 5, 10, 12)
	
	
func _create_uniform_set(p_render_data: RenderData):
	var render_scene_buffers := p_render_data.get_render_scene_buffers()
	
	var input_image: RID = render_scene_buffers.get_color_layer(0)
	var color_uniform := RDUniform.new()
	color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	color_uniform.binding = 0
	color_uniform.add_id(input_image)
	
	var depth_sampler : RID = rd.sampler_create(RDSamplerState.new())
	var depth_texture : RID = render_scene_buffers.get_depth_layer(0)
	var depth_uniform : RDUniform = RDUniform.new()
	depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	depth_uniform.binding = 1
	depth_uniform.add_id(depth_sampler)
	depth_uniform.add_id(depth_texture)
	
	var linear_sampler := RDSamplerState.new()
	linear_sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	linear_sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	linear_sampler.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	
	var coverage_sampler : RID = rd.sampler_create(linear_sampler)
	var coverage_uniform := RDUniform.new()
	coverage_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	coverage_uniform.binding = 2
	coverage_uniform.add_id(coverage_sampler)
	coverage_uniform.add_id(coverage_tex.texture_rd_rid)
	
	var top_shape_sampler : RID = rd.sampler_create(linear_sampler)
	var top_shape_uniform := RDUniform.new()
	top_shape_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	top_shape_uniform.binding = 3
	top_shape_uniform.add_id(top_shape_sampler)
	top_shape_uniform.add_id(top_shape_tex.texture_rd_rid)
	
	var bottom_shape_sampler : RID = rd.sampler_create(linear_sampler)
	var bottom_shape_uniform := RDUniform.new()
	bottom_shape_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	bottom_shape_uniform.binding = 4
	bottom_shape_uniform.add_id(bottom_shape_sampler)
	bottom_shape_uniform.add_id(bottom_shape_tex.texture_rd_rid)
	
	var erosion_sampler : RID = rd.sampler_create(linear_sampler)
	var erosion_uniform := RDUniform.new()
	erosion_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	erosion_uniform.binding = 5
	erosion_uniform.add_id(erosion_sampler)
	erosion_uniform.add_id(erosion_tex.texture_rd_rid)
	
	uniform_set = rd.uniform_set_create([color_uniform, depth_uniform, coverage_uniform, top_shape_uniform, bottom_shape_uniform, erosion_uniform], shader, 0)
	
func _create_matrix_uniform_set() -> void:
	var matrix_uniform := RDUniform.new()
	matrix_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	matrix_uniform.binding = 0

	# Allocate empty buffer just once
	var dummy_data := PackedFloat32Array()
	dummy_data.resize(64)  # 4 mat4 (16 floats each)
	
	matrix_buffer = rd.uniform_buffer_create(dummy_data.size() * 4, dummy_data.to_byte_array())
	matrix_uniform.add_id(matrix_buffer)
	
	var tunable_uniform := RDUniform.new()
	tunable_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	tunable_uniform.binding = 1
	
	#var data := PackedFloat32Array()
	data = PackedByteArray()
	data.resize(112)
	_encode_data()
	
	tunable_buffer = rd.uniform_buffer_create(data.size(), data)
	tunable_uniform.add_id(tunable_buffer)

	matrix_set = rd.uniform_set_create([matrix_uniform, tunable_uniform], shader, 1)
	

func _encode_data() -> void:
	data.encode_u32(0, main_points)
	data.encode_u32(4, optical_depth_points)
	data.encode_float(8, optical_depth_step_exponent)
	data.encode_float(12, optical_depth_erosion_coefficient)
	data.encode_float(16, optical_depth_look_distance)

	data.encode_float(20, max_step_coeff)

	data.encode_float(24, erosion_exponent)
	data.encode_float(28, cloud_density)
	data.encode_float(32, uniform_coverage)
	data.encode_float(36, perlin_worley_blend_exponent)
	data.encode_float(40, top_shape_scale)
	data.encode_float(44, bottom_shape_scale)
	data.encode_float(48, peak)
	data.encode_float(52, 1);
	
	data.encode_float(64, cloud_absp.x)
	data.encode_float(68, cloud_absp.y)
	data.encode_float(72, cloud_absp.z)
	data.encode_float(76, 0.0) #pad
	data.encode_float(80, cloud_scat.x)
	data.encode_float(84, cloud_scat.y)
	data.encode_float(88, cloud_scat.z)
	data.encode_float(92, forward_scatter)
	data.encode_float(96, sheer_direction.x)
	data.encode_float(100, sheer_direction.y)
	data.encode_float(104, sheer_direction.z)
	data.encode_float(108, sheer_speed);

var flag = false
func _render_callback(p_effect_callback_type: EffectCallbackType, p_render_data: RenderData) -> void:
	
	var total_steps = 200.0
	var i = 199.0
	var ray_length = 50000.0
	var total_distance = 5000.0
	
	var distance_to_cover = ray_length - total_distance
	var steps_remaining = total_steps - i
	
	print(distance_to_cover, " ", steps_remaining, " ", pow((distance_to_cover / steps_remaining) / ray_length, 2.0) * ray_length);
	
	if  p_effect_callback_type != effect_callback_type || !shader.is_valid(): return
	
	#if flag: return
	flag = true
	
	var camera
	if Engine.is_editor_hint():
		camera = EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	else:
		camera = get_local_scene().get_viewport().get_camera_3d()
		
	if !uniform_set.is_valid() || !rd.uniform_set_is_valid(uniform_set):
		_create_uniform_set(p_render_data)
		_create_matrix_uniform_set()
	
	var matrix_data := PackedFloat32Array()
	matrix_data.append_array(flatten_projection_column_major(camera.get_camera_projection().inverse())) #inv_proj
	matrix_data.append_array(flatten_projection_column_major(Projection(camera.global_transform))) #inv_view
	matrix_data.append_array(flatten_projection_column_major(camera.get_camera_projection())) #proj
	matrix_data.append_array(flatten_projection_column_major(Projection(camera.global_transform.inverse()))) #view
	rd.buffer_update(matrix_buffer, 0, matrix_data.to_byte_array().size(), matrix_data.to_byte_array())
	
	_encode_data()
	rd.buffer_update(tunable_buffer, 0, data.size(), data)

	var render_scene_buffers := p_render_data.get_render_scene_buffers()
	var size: Vector2i = render_scene_buffers.get_internal_size()
	@warning_ignore("integer_division")
	var x_groups := (size.x - 1) / 8 + 1
	@warning_ignore("integer_division")
	var y_groups := (size.y - 1) / 8 + 1
	var z_groups := 1
	
	var t = Time.get_ticks_msec() / 1000.0
	var loop = fposmod(t, loop_time) / loop_time if (loop_time > 0) else 0.0
	
	var push_constant := PackedFloat32Array([size.x, size.y, camera.fov, camera.near, camera.far, cloud_scale, erosion_scale, loop])
	
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, matrix_set, 1)
	rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups)
	rd.compute_list_end()
	
	
func flatten_projection_column_major(p: Projection) -> PackedFloat32Array:
	var arr := PackedFloat32Array()
	arr.append_array([p.x.x, p.x.y, p.x.z, p.x.w])
	arr.append_array([p.y.x, p.y.y, p.y.z, p.y.w])
	arr.append_array([p.z.x, p.z.y, p.z.z, p.z.w])
	arr.append_array([p.w.x, p.w.y, p.w.z, p.w.w])
	return arr
