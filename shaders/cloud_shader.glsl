#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_image;
layout(set = 0, binding = 2) uniform sampler2D coverage_image;
layout(set = 0, binding = 3) uniform sampler2D top_shape_image;
layout(set = 0, binding = 4) uniform sampler2D bottom_shape_image;
layout(set = 0, binding = 5) uniform sampler3D erosion_image;

layout(set = 1, binding = 0, std140) uniform Matrices {
	mat4 inv_proj_matrix;
	mat4 inv_view_matrix;
	mat4 proj_matrix;
	mat4 view_matrix;
};

layout(set = 1, binding = 1, std140) uniform CloudSettings {
    // quality knobs
    int main_points;
    int optical_depth_points;
    float optical_depth_step_exponent;
    float optical_depth_erosion_coefficient;
    float optical_depth_look_distance;

    // artefact fixes
    float max_step_coeff;

    // density
    float erosion_exponent;
    float cloud_density;
    float uniform_coverage;
    float perlin_worley_blend_exponent;
    float top_shape_scale;
    float bottom_shape_scale;
    float peak;
	float first_step_length;

    // color + misc
    vec3 cloud_absp;
    float _pad0; // padding
    vec3 cloud_scat;
    float forward_scatter;
    vec3 sheer_direction;
    float sheer_speed;
	// float _pad1; // padding
	// float _pad2; // padding
	// float _pad3; // padding
};

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	float camera_fov;
	float near;
	float far;
	float cloud_scale;
	float erosion_scale;
	float time;
};

const float PI = 3.1415926535;
struct Hit { float tmin; float tmax; };
struct Ray { vec3 origin; vec3 dir; vec3 invDir; };

const vec3  planet_center = vec3(0.0, -6000000.0, 0.0);
const float cloud_inner_radius = 6000200.0;
const float cloud_outer_radius = 6001200.0;

// won't be uniforms, will get from somewhere else
const vec3 sun_dir = normalize(vec3(0.5, 0.5, 0.5));
const vec3 sun_color = vec3(1.0, 0.85, 0.75) * 2.0;
const vec3 ambient_color = vec3(0.1, 0.125, 0.15) * 2.0;

float henyeyGreenstein(float g, float cosTheta)
{
    float g2 = g * g;
    float denominator = pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5);
    return ((1.0 - g2) / (4.0 * PI * denominator));
}

float compute_distance_from_view_space(vec2 uv_norm, ivec2 size, float depth) {
    float z_ndc = 1.0 - depth;
    float z = z_ndc * 2.0 - 1.0;
    vec2 ndc_xy = uv_norm * 2.0 - 1.0;

    float z_linear = (2.0 * near * far) / (far + near - z * (far - near));

    float aspect = float(size.x) / float(size.y);
    float tan_half_fov = tan(radians(camera_fov) / 2.0);

    vec3 view_pos;
    view_pos.z = -z_linear;
    view_pos.x = ndc_xy.x * -z_linear * tan_half_fov * aspect;
    view_pos.y = ndc_xy.y * -z_linear * tan_half_fov;

	return(length(view_pos));
}

// x = near hit, if inside the sphere it is equal to 0
// y = far hit.  if the ray doesn't intersect, we get -1
bool ray_sphere(vec3 sphere_center, float radius, vec3 ray_origin, vec3 ray_dir, out vec2 hit) {
    vec3 offset = ray_origin - sphere_center;
    float b = 2.0 * dot(offset, ray_dir);
    float c = dot(offset, offset) - radius * radius;
    float discriminant = b * b - 4.0 * c;

    if (discriminant > 0.0) {
    	float sqrt_disc = sqrt(discriminant);
   		float t0 = max(0, (-b - sqrt_disc) * 0.5);
    	float t1 = (-b + sqrt_disc) * 0.5;
		if (t1 >= 0.0f)
		{
			hit = vec2(t0, t1);
			return true;
		}
    }
	return false;
}


bool BBoxIntersect(const vec3 boxMin, const vec3 boxMax, const Ray r, out Hit hit) {
	vec3 tbot = r.invDir * (boxMin - r.origin);
	vec3 ttop = r.invDir * (boxMax - r.origin);
	vec3 tmin = min(ttop, tbot);
	vec3 tmax = max(ttop, tbot);
	vec2 t = max(tmin.xx, tmin.yz);
	float t0 = max(t.x, t.y);
	t = min(tmax.xx, tmax.yz);
	float t1 = min(t.x, t.y);
	hit.tmin = t0;
	hit.tmax = t1;
	return t1 > max(t0, 0.0);
}


float altitude(vec3 p) {
    return length(p - planet_center);
}


float get_normalised_height(vec3 position){
	float altitude = altitude(position);
	float range = cloud_outer_radius - cloud_inner_radius;
	float normalised = (altitude - cloud_inner_radius) / range;
	return normalised;
}


float rand_float(vec2 p) {
    float r = dot(p, vec2(127.1, 311.7));
    return fract(sin(r) * 43758.5453);
}


float get_next_step(float total_distance, float current_distance, uint split, float power)
{
	float current01 = current_distance / total_distance;
    float next_u = pow(pow(current01, 1.0/power) + 1.0/float(split), power);
    float t_next = next_u * total_distance;
    float t_curr = current01 * total_distance;
    return t_next - t_curr;
}


float get_erosion(vec3 position, vec3 erosion_offset) {
	vec2 erosion_tex = texture(erosion_image, (position.xyz * (1.0 / erosion_scale))  + erosion_offset).rg;
	float perlin = erosion_tex.x;
	float worley = erosion_tex.y;
	float normalised_y = get_normalised_height(position);
	float erosion = mix(perlin, worley, pow(normalised_y, perlin_worley_blend_exponent));
	return pow(max(erosion, 0.0), erosion_exponent);
}

float get_coverage(vec2 position) {
	float a = texture(coverage_image, (position * (1.0 / cloud_scale))).r;
	float b = texture(coverage_image, ((position + vec2(1231.0, 123111.0)) * (1.0 / (cloud_scale * 2.1)))).r;

	return clamp(a + b + uniform_coverage, 0.0, 1.0);
}


float get_profile(vec3 position)
{
	float h = get_normalised_height(position);

	float up = (texture(top_shape_image, (position.xz * (1.0 / (cloud_scale * top_shape_scale)))).r + 1.0);
	float down = (texture(bottom_shape_image, (position.xz * (1.0 / (cloud_scale * bottom_shape_scale)))).r + 1.0);

	float max_height = peak + (up * (1.0 - peak));
	float min_height = peak - (down * peak);

	down   	= smoothstep(min_height, peak, h);
	up 		= smoothstep(max_height, peak, h);

	return (1.0 - (up * down));
}


float density_at_pos_simple(vec3 position, float erosion, float coverage) {
	float profile = coverage - get_profile(position);
	float density = max(0.0, profile - erosion);

	return density * cloud_density;
}


float density_at_pos_expensive(vec3 position, vec3 erosion_offset, float coverage) {
	float erosion = get_erosion(position.xyz, erosion_offset);

	float profile = coverage - get_profile(position);
	float density = max(0.0, profile - erosion);

	return density * cloud_density;
}

float calculate_optical_depth(vec3 ray_origin, vec3 ray_dir, float ray_length, vec3 erosion_offset) {
	vec3 position = ray_origin;

	float opticalDepth = 0.0;

	float erosion = get_erosion(position.xyz, erosion_offset) * optical_depth_erosion_coefficient; //we assume erosion is the same the entire way

	float total_distance = 0.0;

	for (int i = 0; i < optical_depth_points; i++)
	{
		float step_size = get_next_step(ray_length, total_distance, optical_depth_points, optical_depth_step_exponent);
		total_distance += step_size;
		vec3 step = ray_dir * step_size;

		float coverage = get_coverage(position.xz);

		if (coverage == 0) {
			position += step;
			continue;
		}

		float localDensity = density_at_pos_simple(position, erosion, coverage);
		//float localDensity = density_at_pos_expensive(position, erosion_offset, coverage);

		opticalDepth += localDensity * step_size;
        position += step;
	}

	return opticalDepth;
}

const int total_steps = 300;
const float near_length = 4000.0;
const float near_step_size = 50;

vec3 calculate_light(vec3 ray_origin, vec3 ray_dir, float ray_length, float max_distance, vec3 original_color, vec2 uv_norm){

	float cos_theta = dot(ray_dir, sun_dir);
	float primary_phase = henyeyGreenstein(forward_scatter, cos_theta);
	float secondary_phase = mix(primary_phase, 1.0, 0.8);

	float total_optical_depth = 0.0;

	vec3 position = ray_origin;

	vec3 erosion_offset = sheer_direction * sheer_speed * time;

	float total_distance = 0.0;
	vec3 total_in_scatter = vec3(0.0);

	float step_size;
	float noise_step_offset = rand_float(vec2(gl_GlobalInvocationID.xy + vec2(time)) / raster_size);
	position = position + (noise_step_offset * ray_dir * near_step_size);

	float near_distance = near_length + (noise_step_offset * near_step_size);

	float far_distance = ray_length - near_distance;

	int counter = 0;

	float local_density = 0.0;

	for (uint i = 0; i < total_steps; i++)
	{
		counter ++;
		vec3 step;

		if (total_distance > near_distance) {
			float normalised_distance_along_ray = (total_distance - near_distance) / far_distance;

			float offset = noise_step_offset / float(total_steps);

			float distance_left = ray_length - total_distance;
			float steps_left = float(total_steps - (i + 1));

			float linear_step_size = distance_left / steps_left;
			float size_increase = mix(1.5, 0.5, local_density);

			step_size = max(mix(near_step_size, linear_step_size, normalised_distance_along_ray + (offset * size_increase) ), near_step_size) * size_increase;
		}
		else {
			step_size = near_step_size;
		}

		if (total_distance + step_size > max_distance)
		{
			step_size = max_distance - total_distance;
		}

		step = ray_dir * step_size;
		position += step;
		total_distance += step_size;

		float coverage = get_coverage(position.xz);
		if (coverage == 0) 
		{
			local_density = 0.0;
			if (total_distance >= max_distance) break;
			continue;
		}

		if (total_optical_depth > 4.0 || total_distance > max_distance || total_distance > ray_length) break;

		
		float step_size_multiplier = min(step_size, max_step_coeff);

		float optical_depth = calculate_optical_depth(position, sun_dir, optical_depth_look_distance, erosion_offset); //hardcoded look 100m for now (actually maybe this is fine forever)

		local_density = density_at_pos_expensive(position, erosion_offset, coverage);

		total_optical_depth += local_density * step_size_multiplier;

		vec3 absorption 		= cloud_absp * (optical_depth + total_optical_depth);
		vec3 out_scatter 		= cloud_scat * (optical_depth + total_optical_depth);
		vec3 direct_scatter 	= cloud_scat * local_density * primary_phase;
		vec3 secondary_scatter	= cloud_scat * local_density * (pow(1.0 - local_density, 0.5)) * secondary_phase;
		vec3 ambient_scatter	= cloud_scat * local_density * (pow(1.0 - local_density, 0.5)) * ambient_color;

		vec3 transmittance = exp(-absorption -out_scatter);
		vec3 ambient_transmittance = exp(-total_optical_depth * cloud_scat);

		total_in_scatter += step_size_multiplier * (((direct_scatter + secondary_scatter) * transmittance * sun_color) + (ambient_scatter * ambient_transmittance));

		if (total_distance >= max_distance) break;
	}

	float transmittance = exp(-total_optical_depth);

	return (original_color * transmittance) + (total_in_scatter);
}


void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	vec2 uv_norm = vec2(uv) / raster_size;

	vec3 cam_pos = inv_view_matrix[3].xyz;

	vec2 ndc = vec2(uv_norm.x, 1.0 - uv_norm.y) * 2.0 - 1.0;
	vec4 clip = vec4(ndc, 1.0, 1.0);
	vec4 view = inv_proj_matrix * clip;
	view /= view.w;
	vec4 world = inv_view_matrix * view;

	vec3 ray_dir = normalize(world.xyz - cam_pos);

	vec4 original_color = imageLoad(color_image, uv);
	vec4 out_color = original_color;

	float raw_depth = texture(depth_image, uv_norm).r;
	float frag_dist = (raw_depth > 0.0) ? compute_distance_from_view_space(uv_norm, ivec2(raster_size), raw_depth) : 1e9;

	Hit hit = Hit(0.0, 0.0);
	Ray r = Ray(cam_pos, ray_dir, 1.0 / ray_dir);

	// x = near hit, if inside the sphere it is equal to 0
	// y = far hit.  if the ray doesn't intersect, we get -1
	vec2 inner_hit = vec2(0.0);
	vec2 outer_hit = vec2(0.0);

	bool inner_collision = ray_sphere(planet_center, cloud_inner_radius, cam_pos, ray_dir, inner_hit);
	bool outer_collision = ray_sphere(planet_center, cloud_outer_radius, cam_pos, ray_dir, outer_hit);

	if(inner_collision || outer_collision)
	{
		vec3 hit_pos = vec3(0.0);
		float ray_length = 0.0;

		if (outer_hit.x == 0.0 && !inner_collision) { //inside the cloud layer looking out
			hit_pos = cam_pos;
			ray_length = outer_hit.y;
		}
		else if (outer_hit.x == 0.0 && inner_hit.x > 0.0) { //inside the cloud layer looking in
			hit_pos = cam_pos;
			ray_length = inner_hit.x;
		}
		else if (inner_hit.x == 0.0 && outer_hit.x == 0.0) { //inside the shell looking out
			hit_pos = cam_pos + (ray_dir * inner_hit.y);
			ray_length = outer_hit.y - inner_hit.y;
		}
		else if (inner_hit.x > 0.0 && outer_hit.x > 0.0) { //outside the shell looking in
			hit_pos = cam_pos + (ray_dir * outer_hit.x);
			ray_length = inner_hit.x - outer_hit.x;
		}
		else if (!inner_collision && outer_hit.x > 0.0) { //outside the shell looking through
			hit_pos = cam_pos + (ray_dir * outer_hit.x);
			ray_length = outer_hit.y - outer_hit.x;
		}
		else if (inner_collision || outer_collision) {
			original_color.rgb = vec3(1.0, 0.0, 1.0);
		}


		//if (ray_length > 50000.0) original_color.rgb += vec3(0.5, 0.0, 0.5);
		//ray_length = min(50000.0, ray_length);

		//float noise_step_offset = rand_float(vec2(gl_GlobalInvocationID.xy) / raster_size) * 1.0;
		//hit_pos += (ray_dir * noise_step_offset);
		//ray_length = ray_length * (1.0 - (noise_step_offset * 0.2));

		if (ray_length > 0.0 && length(hit_pos - cam_pos) < 1000000.0)
		{
			out_color.rgb = calculate_light(hit_pos, ray_dir, ray_length, frag_dist - length(hit_pos - cam_pos), original_color.rgb, uv_norm);
		}
	}

	imageStore(color_image, uv, out_color);
}