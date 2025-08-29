#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(rg16f, set = 0, binding = 0) uniform image3D color_image;

layout(push_constant, std430) uniform Params {
	float worley_frequency;
	float perlin_frequency;
	float octaves;
	float offset;
	
};

// helpers
vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec4 mod289(vec4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }

vec4 permute(vec4 x) { return mod289(((x*34.0)+10.0)*x); }

vec4 taylorInvSqrt(vec4 r) {
    return 1.79284291400159 - 0.85373472095314 * r;
}

vec3 fade(vec3 t) {
    return t*t*t*(t*(t*6.0-15.0)+10.0);
}

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

// periodic 3D Perlin noise
float pnoise(vec3 P, vec3 rep)
{
    vec3 Pi0 = mod(floor(P), rep);        // Integer part, modulo repeat
    vec3 Pi1 = mod(Pi0 + 1.0, rep);       // +1 in each axis
    Pi0 = mod289(Pi0);
    Pi1 = mod289(Pi1);
    vec3 Pf0 = fract(P);
    vec3 Pf1 = Pf0 - 1.0;
    vec4 ix = vec4(Pi0.x, Pi1.x, Pi0.x, Pi1.x);
    vec4 iy = vec4(Pi0.y, Pi0.y, Pi1.y, Pi1.y);
    vec4 iz0 = vec4(Pi0.z);
    vec4 iz1 = vec4(Pi1.z);

    vec4 ixy = permute(permute(ix) + iy);
    vec4 ixy0 = permute(ixy + iz0);
    vec4 ixy1 = permute(ixy + iz1);

    vec4 gx0 = fract(ixy0 * (1.0 / 7.0)) * 2.0 - 1.0;
    vec4 gy0 = fract(floor(ixy0 * (1.0 / 7.0)) * (1.0 / 7.0)) * 2.0 - 1.0;
    vec4 gz0 = 1.0 - abs(gx0) - abs(gy0);
    vec4 sx0 = step(gz0, vec4(0.0));
    gx0 -= sx0 * (step(0.0, gx0) - 0.5);
    gy0 -= sx0 * (step(0.0, gy0) - 0.5);

    vec4 gx1 = fract(ixy1 * (1.0 / 7.0)) * 2.0 - 1.0;
    vec4 gy1 = fract(floor(ixy1 * (1.0 / 7.0)) * (1.0 / 7.0)) * 2.0 - 1.0;
    vec4 gz1 = 1.0 - abs(gx1) - abs(gy1);
    vec4 sx1 = step(gz1, vec4(0.0));
    gx1 -= sx1 * (step(0.0, gx1) - 0.5);
    gy1 -= sx1 * (step(0.0, gy1) - 0.5);

    vec3 g000 = vec3(gx0.x,gy0.x,gz0.x);
    vec3 g100 = vec3(gx0.y,gy0.y,gz0.y);
    vec3 g010 = vec3(gx0.z,gy0.z,gz0.z);
    vec3 g110 = vec3(gx0.w,gy0.w,gz0.w);
    vec3 g001 = vec3(gx1.x,gy1.x,gz1.x);
    vec3 g101 = vec3(gx1.y,gy1.y,gz1.y);
    vec3 g011 = vec3(gx1.z,gy1.z,gz1.z);
    vec3 g111 = vec3(gx1.w,gy1.w,gz1.w);

    vec4 norm0 = taylorInvSqrt(vec4(dot(g000,g000), dot(g010,g010),
                                    dot(g100,g100), dot(g110,g110)));
    g000 *= norm0.x;
    g010 *= norm0.y;
    g100 *= norm0.z;
    g110 *= norm0.w;
    vec4 norm1 = taylorInvSqrt(vec4(dot(g001,g001), dot(g011,g011),
                                    dot(g101,g101), dot(g111,g111)));
    g001 *= norm1.x;
    g011 *= norm1.y;
    g101 *= norm1.z;
    g111 *= norm1.w;

    float n000 = dot(g000, Pf0);
    float n100 = dot(g100, vec3(Pf1.x, Pf0.y, Pf0.z));
    float n010 = dot(g010, vec3(Pf0.x, Pf1.y, Pf0.z));
    float n110 = dot(g110, vec3(Pf1.x, Pf1.y, Pf0.z));
    float n001 = dot(g001, vec3(Pf0.x, Pf0.y, Pf1.z));
    float n101 = dot(g101, vec3(Pf1.x, Pf0.y, Pf1.z));
    float n011 = dot(g011, vec3(Pf0.x, Pf1.y, Pf1.z));
    float n111 = dot(g111, Pf1);

    vec3 fade_xyz = fade(Pf0);
    vec4 n_z = mix(vec4(n000, n100, n010, n110),
                   vec4(n001, n101, n011, n111), fade_xyz.z);
    vec2 n_yz = mix(n_z.xy, n_z.zw, fade_xyz.y);
    float n_xyz = mix(n_yz.x, n_yz.y, fade_xyz.x); 
    return 2.2 * n_xyz;
}


void main() {
	ivec3 uv = ivec3(gl_GlobalInvocationID.xyz);
	vec3 norm_uv = vec3(uv) / vec3(imageSize(color_image));

	vec3 offset_pos = norm_uv + vec3(offset);

	float w_frequency = worley_frequency;
	float p_frequency = perlin_frequency;
    float amp = 0.5;
    float total_worley = 0.0;
	float total_perlin = 0.0;

    for (float i = 1.0; i <= octaves; i++)
    {
      total_worley += amp * worley_noise(offset_pos, w_frequency, true);
	  total_perlin += amp * pnoise(p_frequency * offset_pos, vec3(p_frequency));
      w_frequency *= 2.0;
	  p_frequency *= 2.0;
      amp *= 0.5;
    }

	imageStore(color_image, uv, vec4(total_perlin, total_worley, 0.0, 0.0));
}