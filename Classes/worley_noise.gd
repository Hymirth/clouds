extends RefCounted
class_name Worley_Noise

var rd			: RenderingDevice
var shader		: RID
var pipeline 	: RID

var file_2d
var file_3d

func _init() -> void:
	rd = RenderingServer.get_rendering_device()
	file_2d = load("res://shaders/worley_noise.glsl")
	file_3d = load("res://shaders/worley_noise_3d.glsl")


func generate_2d(size: int, frequency : float, octaves : float, offset : float = 0.0) -> Texture2DRD:
	var initial_spirv = file_2d.get_spirv()
	shader = rd.shader_create_from_spirv(initial_spirv)
	pipeline = rd.compute_pipeline_create(shader)
	
	var worley_texture_2d = Texture2DRD.new()
	worley_texture_2d.texture_rd_rid = _create_rd_texture(size)
	
	var texture_uniform = RDUniform.new()
	texture_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	texture_uniform.binding = 0
	texture_uniform.add_id(worley_texture_2d.texture_rd_rid)
	
	var uniform_set = rd.uniform_set_create([texture_uniform], shader, 0)

	@warning_ignore("integer_division")
	var groups := (size - 1) / 8 + 1
	
	var push_constant := PackedFloat32Array([frequency, octaves, offset, 0.0])
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
	rd.compute_list_dispatch(compute_list, groups, groups, 1)
	rd.compute_list_end()
	
	return worley_texture_2d
	
func generate_3d(size: int, frequency : float, octaves : float, offset : float = 0.0) -> Texture3DRD:
	var initial_spirv = file_3d.get_spirv()
	shader = rd.shader_create_from_spirv(initial_spirv)
	pipeline = rd.compute_pipeline_create(shader)
	
	var worley_texture_3d = Texture3DRD.new()
	worley_texture_3d.texture_rd_rid = _create_rd_texture(size, true)
	
	var texture_uniform = RDUniform.new()
	texture_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	texture_uniform.binding = 0
	texture_uniform.add_id(worley_texture_3d.texture_rd_rid)
	
	var uniform_set = rd.uniform_set_create([texture_uniform], shader, 0)

	@warning_ignore("integer_division")
	var groups := (size - 1) / 8 + 1
	
	var push_constant := PackedFloat32Array([frequency, octaves, offset, 0.0])
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
	rd.compute_list_dispatch(compute_list, groups, groups, groups)
	rd.compute_list_end()
	
	return worley_texture_3d

func _create_rd_texture(size: int, is_3d: bool=false) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.width = size
	fmt.height = size
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D if is_3d else RenderingDevice.TEXTURE_TYPE_2D
	if is_3d:
		fmt.depth = size
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var view := RDTextureView.new()
	return rd.texture_create(fmt, view)
	
