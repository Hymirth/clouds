#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(r32f, set = 0, binding = 0) uniform image3D color_image;

layout(push_constant, std430) uniform Params {
	float base_frequency;
	float octaves;
	float offset;
	float pad;
};

vec3 rand_3d(vec3 p) {
    p = vec3(dot(p, vec3(127.1, 311.7, 87.1)),
             dot(p, vec3(269.5, 183.3, 601.2)),
			 dot(p, vec3(56.5, 450.3, 350.5)));
    return fract(sin(p) * 43758.5453);
}

float worley_noise(vec3 pos, float frequency, bool tilable){

  	vec3 cs = floor(pos * frequency);
  	vec3 local_pos = fract(pos * frequency);

  	float shortest_distance = 1e20;
  	for (int x = -1; x < 2; x++) {
    	for (int y = -1; y < 2; y++) {
			for (int z = -1; z < 2; z++) {
			    vec3 cell_position = vec3(cs.x + float(x), cs.y + float(y), cs.z + float(z));

				if (tilable) {
					cell_position = mod(cell_position, frequency);
				}


				vec3 point_position = rand_3d(cell_position) + vec3(x, y, z);

				float distance = length(point_position - local_pos);

				if (distance < shortest_distance) shortest_distance = distance;
			}
    }
  }

  return shortest_distance / sqrt(3.0);
}


void main() {
	ivec3 uv = ivec3(gl_GlobalInvocationID.xyz);
	vec3 norm_uv = vec3(uv) / vec3(imageSize(color_image));

	vec3 offset_pos = norm_uv + vec3(offset);

	float frequency = base_frequency;
    float amp = 0.5;
    float total = 0.0;

    for (float i = 1.0; i <= octaves; i++)
    {
      total += amp * worley_noise(offset_pos, frequency, true);
      frequency *= 2.0;
      amp *= 0.5;
    }

	imageStore(color_image, uv, vec4(total, 0.0, 0.0, 0.0));
}