#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform image2D color_image;

layout(push_constant, std430) uniform Params {
	float base_frequency;
	float octaves;
	float offset;
	float pad;
};

vec2 rand_2d(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)),
             dot(p, vec2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}

float worley_noise(vec2 pos, float frequency, bool tilable){

  vec2 cs = floor(pos * frequency);
  vec2 local_pos = fract(pos * frequency);

  float shortest_distance = 1e20;
  for (int x = -1; x < 2; x++) {
    for (int y = -1; y < 2; y++) {

      vec2 cell_position = vec2(cs.x + float(x), cs.y + float(y));

      if (tilable) {
        cell_position = mod(cell_position, frequency);
      }


      vec2 point_position = rand_2d(cell_position) + vec2(x, y);

      float distance = length(point_position - local_pos);

      if (distance < shortest_distance) shortest_distance = distance;

    }
  }

  return shortest_distance / sqrt(2.0);
}


void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	vec2 norm_uv = vec2(uv) / vec2(imageSize(color_image));

  vec2 offset_pos = norm_uv + vec2(offset);

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