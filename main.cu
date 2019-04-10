#include <iostream>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <float.h>

#include <cuda.h>
#include <cuda_runtime.h>

#include <curand.h>
#include <curand_kernel.h>

#include <cub/cub.cuh>

#include "sphere_list.cuh"

#define NX 200
#define NY 100
#define NS 2
#define MAX_DEPTH 24

__device__ vec3 sky(const ray &r) {
    vec3 unit_direction = unit_vector(r.direction());
    float t = 0.5 * unit_direction.y() + 1.0;
    return (1.0-t) * vec3(1.0, 1.0, 1.0) + t*vec3(0.5, 0.7, 1.0);
}

__device__ vec3 color(curandState &local_state, const ray &r, sphere_list *world) {
    hit_record rec;
    ray scattered = r;
    vec3 attenuation[MAX_DEPTH];
    int num_hits = 0;
    vec3 col = vec3(0, 0, 0);

    for (int i = 0; i < MAX_DEPTH; i++) {
        if (hit(world, r, 0.001, FLT_MAX, rec)) {
            if (scatter(local_state, rec.mat_ptr, r, rec, attenuation[i], scattered)) {
                num_hits++;
            } else {
                break;
            }
        } else {
            col = sky(scattered);
            break;
        }
    }

    for (int i = num_hits-1; i >= 0; i--) {
        col *= attenuation[i];
    }

    return col;
}

__global__ void setup_kernel(curandState * state, unsigned long seed)
{
    int id = threadIdx.x + blockIdx.x * blockDim.x;
    curand_init((seed<<20)+id, 0, 0, &state[id]);
}

__device__ vec3 add_vec3(const vec3 &v1, const vec3 &v2) {
    return v1 + v2;
}

__global__ void kernel(curandState* global_state, int nx, int ny, sphere_list *world, unsigned char *out) {
    int id = threadIdx.x + blockIdx.x * blockDim.x;
    curandState local_state = global_state[id];

#if NS > 1
    typedef cub::BlockReduce<vec3, NS> BlockReduce;
    __shared__ typename BlockReduce::TempStorage temp_storage;
#endif

    vec3 lower_left_corner = vec3(-2.0, -1.0, -1.0);
    vec3 horizontal = vec3(4.0, 0.0, 0.0);
    vec3 vertical = vec3(0.0, 2.0, 0.0);
    vec3 origin = vec3(0.0, 0.0, 0.0);

    int n = blockIdx.x;
    int j = ny-n/nx-1;
    int i = n%nx;

    float u = (float(i) + curand_uniform(&local_state)) / float(nx);
    float v = (float(j) + curand_uniform(&local_state)) / float(ny);

    ray r = ray(origin, lower_left_corner + u*horizontal + v*vertical);
    vec3 col = color(local_state, r, world);
    col/=float(NS);

#if NS > 1
    col = BlockReduce(temp_storage).Reduce(col, add_vec3);
#endif

    if (threadIdx.x == 0) {
        out[n*3+0] = int(255.99*sqrt(col.r()));
        out[n*3+1] = int(255.99*sqrt(col.g()));
        out[n*3+2] = int(255.99*sqrt(col.b()));
    }
}

int main(void) {
    curandState* device_states;
    cudaMalloc(&device_states, NX*NY*NS*sizeof(curandState));

    setup_kernel<<<NX*NY,NS>>>(device_states, time(NULL));

    size_t BUFFER_SIZE = sizeof(unsigned char)*NX*NY*3;

    printf("P3\n%d %d\n255\n", NX, NY);

    sphere_list *world = make_shared_sphere_list(2);
    sphere **list = world->list;
    list[0] = make_shared_sphere(vec3(0,0,-1), 0.5, make_shared_lambertian(vec3(0.8, 0.3, 0.3)));
    list[1] = make_shared_sphere(vec3(0,-100.5,-1), 100, make_shared_lambertian(vec3(0.8, 0.6, 0.2)));
    // list[2] = make_shared_sphere(vec3(1,0,-1), 0.5, make_shared_metal(vec3(0.8, 0.6, 0.2), 0.8));
    // list[3] = make_shared_sphere(vec3(-1,0,-1), 0.5, make_shared_dielectric(1.5));
    // list[4] = make_shared_sphere(vec3(-1,0,-1), -0.45, make_shared_dielectric(1.5));
    
    unsigned char *out = (unsigned char*)malloc(BUFFER_SIZE); // host ouput
    unsigned char *d_out; // device output
    cudaMalloc(&d_out, BUFFER_SIZE);

    kernel<<<NX*NY,NS>>>(device_states, NX, NY, world, d_out);

    cudaMemcpy(out, d_out, BUFFER_SIZE, cudaMemcpyDeviceToHost);

    for (int n = 0; n < NX*NY; n++) {
        printf("%d %d %d\n", out[n*3+0], out[n*3+1], out[n*3+2]);
    }

    cudaFree(d_out);
    free(out);

    clean_up_sphere_list(world);

    return 0;
}