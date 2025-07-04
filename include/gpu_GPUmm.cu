// JNI
#include <jni.h>
#include "gpu_GPUmm.h"

// CUDA
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cusparse.h>

#include <stdio.h>
#include <cassert>
#include <iostream>
#include <fstream>
#include <cstring>
#include <sstream>
#include <sys/time.h>
#include <string>
#include <cstdlib>
#include <cmath>
#include <cstdint>

using namespace std;

// ====== Optimiations ====
#define REGULATE_GPU  // ON
//#define OPT_TRIANGULAR_MM      // OFF
#define OPT_SPARSE_MATRIX        // OFF
#define OPT_EARLY_TERMINATION  // ON


// ====== Vars ======
#define THREADS_PER_BLOCK 512
#define REGULATE_BATCH 1000

#define MAX_N 30000ul
//#define MAX_N 16384ul
#define MAX_NNZ ((MAX_N) * 20)

// sparse matrix optimization
#ifdef OPT_SPARSE_MATRIX
  #define MAGIC_SPARSE_THRESHOLD1 0.01
  #define MAGIC_SPARSE_THRESHOLD2 12
#else
  #define MAGIC_SPARSE_THRESHOLD1 0
  #define MAGIC_SPARSE_THRESHOLD2 0
#endif

// early termination optimization
#define MAGIC_EARLY_TERMINATION_THRESHOLD 256





const float alpha = 1.0;
const float beta = 0.0;

// TODO: check which API needs sync
float *gpu_m, *gpu_m2, *gpu_csr_val;
int *gpu_nnz_row, *gpu_csr_rowptr, *gpu_csr_colind;

cublasHandle_t handle_c;
cusparseHandle_t handle_s;
cusparseHandle_t handle_ss;
cusparseMatDescr_t descr;

// ====== Helpers ======

const char* cublasGetErrorString(cublasStatus_t status) {
  switch(status) {
    case CUBLAS_STATUS_SUCCESS: return "CUBLAS_STATUS_SUCCESS";
    case CUBLAS_STATUS_NOT_INITIALIZED: return "CUBLAS_STATUS_NOT_INITIALIZED";
    case CUBLAS_STATUS_ALLOC_FAILED: return "CUBLAS_STATUS_ALLOC_FAILED";
    case CUBLAS_STATUS_INVALID_VALUE: return "CUBLAS_STATUS_INVALID_VALUE";
    case CUBLAS_STATUS_ARCH_MISMATCH: return "CUBLAS_STATUS_ARCH_MISMATCH";
    case CUBLAS_STATUS_MAPPING_ERROR: return "CUBLAS_STATUS_MAPPING_ERROR";
    case CUBLAS_STATUS_EXECUTION_FAILED: return "CUBLAS_STATUS_EXECUTION_FAILED";
    case CUBLAS_STATUS_INTERNAL_ERROR: return "CUBLAS_STATUS_INTERNAL_ERROR";
  }
  return "unknown error";
}

const char* cusparseGetErrorString(cusparseStatus_t status) {
    return ::cusparseGetErrorString(status);
}

#define CUDA_CALL(func) { \
  cudaError_t e = (func); \
  if(e != cudaSuccess) {\
    cout << "CUDA Error in " << __FILE__ << ":" << __LINE__ << ": " << cudaGetErrorString(e) << endl; \
    assert(false);\
  }\
}

#define CUBLAS_CALL(func) {\
  cublasStatus_t e = (func); \
  if(e != CUBLAS_STATUS_SUCCESS) {\
    cout << "cuBlas Error in " << __FILE__ << ":" << __LINE__ << ": " << cublasGetErrorString(e) << endl; \
    assert(false);\
  }\
}

#define CUSPARSE_CALL(func) {\
  cusparseStatus_t e = (func); \
  if(e != CUSPARSE_STATUS_SUCCESS) {\
    cout << "cusparse Error in " << __FILE__ << ":" << __LINE__ << ": " << cusparseGetErrorString(e) << endl; \
    assert(false);\
  }\
}

// ===== functional =====

bool
staySparse(int n, int nnz) {
  if (nnz < n * n * MAGIC_SPARSE_THRESHOLD1) {
    return true;
  } else {
    return false;
  }
}

//original kernel
__global__ void countNNZ_kernel(const float* mat, int size, int* nnz_counter) {
  for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < size; i += blockDim.x * gridDim.x) {
      if (mat[i] != 0.0f) {
          //add 1 to nnz_counter when mat[i] isn't 0
          atomicAdd(nnz_counter, 1);
      }
  }
}

void
countNNZ(cusparseHandle_t handle, cusparseMatDescr_t descr,
         int* nnzrow_unused, int &nnz_total, float* gpu_m, int n) {
    int* d_nnz_total = NULL;
    CUDA_CALL(cudaMalloc(&d_nnz_total, sizeof(int)));
    CUDA_CALL(cudaMemset(d_nnz_total, 0, sizeof(int)));

    //use original kernel
    //nnzrow is unused, so it may be deleted
    countNNZ_kernel<<<256, 256>>>(gpu_m, n * n, d_nnz_total);

    CUDA_CALL(cudaMemcpy(&nnz_total, d_nnz_total, sizeof(int), cudaMemcpyDeviceToHost));
    CUDA_CALL(cudaFree(d_nnz_total));
    CUDA_CALL(cudaDeviceSynchronize());
    cout << "  count nnz [nnz_total=" << nnz_total << "]\n";
}

//countResultNNZ has been deleted

//cusparseSdense2csr->cusparseDenseToSparse
void
cudaDense2sparse(cusparseHandle_t handle, cusparseMatDescr_t descr,
  float* gpu_m, int *nnz_row_unused,
  float* &csr_val, int* &csr_rowptr, int* &csr_colind,
  int nnz_total, int n) {
cusparseDnMatDescr_t mat_dense;
cusparseSpMatDescr_t mat_sparse;
cusparseIndexBase_t indexBase = cusparseGetMatIndexBase(descr);

CUSPARSE_CALL(cusparseCreateDnMat(&mat_dense, n, n, n, gpu_m, CUDA_R_32F, CUSPARSE_ORDER_COL));
CUSPARSE_CALL(cusparseCreateCsr(&mat_sparse, n, n, nnz_total,
                     csr_rowptr, csr_colind, csr_val,
                     CUSPARSE_INDEX_32I, CUSPARSE_INDEX_32I,
                     indexBase, CUDA_R_32F));
size_t bufferSize = 0;
void* dBuffer    = NULL;
CUSPARSE_CALL(cusparseDenseToSparse_bufferSize(handle, mat_dense, mat_sparse,
                                    CUSPARSE_DENSETOSPARSE_ALG_DEFAULT, &bufferSize));
if (bufferSize > 0) { CUDA_CALL(cudaMalloc(&dBuffer, bufferSize)); }

CUSPARSE_CALL(cusparseDenseToSparse_convert(handle, mat_dense, mat_sparse,
                                 CUSPARSE_DENSETOSPARSE_ALG_DEFAULT, dBuffer));

if (bufferSize > 0) { CUDA_CALL(cudaFree(dBuffer)); }
CUSPARSE_CALL(cusparseDestroyDnMat(mat_dense));
CUSPARSE_CALL(cusparseDestroySpMat(mat_sparse));

CUDA_CALL(cudaDeviceSynchronize());
cout << "  [GPU] dense matrix => sparse matrix \n";
}

//cusparseScsr2dense->cusparseSparseToDense
void
sparse2dense(cusparseHandle_t handle, cusparseMatDescr_t descr,
             float* csr_val, int* csr_rowptr, int* csr_colind,
             float* gpu_m, int n) {
    int nnz_total;
    int first_row_offset, last_row_offset;
    CUDA_CALL(cudaMemcpy(&first_row_offset, csr_rowptr, sizeof(int), cudaMemcpyDeviceToHost));
    CUDA_CALL(cudaMemcpy(&last_row_offset, csr_rowptr + n, sizeof(int), cudaMemcpyDeviceToHost));
    nnz_total = last_row_offset - first_row_offset;

    cusparseSpMatDescr_t mat_sparse;
    cusparseDnMatDescr_t mat_dense;
    cusparseIndexBase_t indexBase = cusparseGetMatIndexBase(descr);
    
    CUSPARSE_CALL(cusparseCreateCsr(&mat_sparse, n, n, nnz_total,
                                    csr_rowptr, csr_colind, csr_val,
                                    CUSPARSE_INDEX_32I, CUSPARSE_INDEX_32I,
                                    indexBase, CUDA_R_32F));
    CUSPARSE_CALL(cusparseCreateDnMat(&mat_dense, n, n, n, gpu_m, CUDA_R_32F, CUSPARSE_ORDER_COL));

    size_t bufferSize = 0;
    void* dBuffer    = NULL;
    CUSPARSE_CALL(cusparseSparseToDense_bufferSize(handle, mat_sparse, mat_dense,
                                                   CUSPARSE_SPARSETODENSE_ALG_DEFAULT, &bufferSize));
    if (bufferSize > 0) { CUDA_CALL(cudaMalloc(&dBuffer, bufferSize)); }

    CUSPARSE_CALL(cusparseSparseToDense(handle, mat_sparse, mat_dense,
                                        CUSPARSE_SPARSETODENSE_ALG_DEFAULT, dBuffer));

    if (bufferSize > 0) { CUDA_CALL(cudaFree(dBuffer)); }
    CUSPARSE_CALL(cusparseDestroySpMat(mat_sparse));
    CUSPARSE_CALL(cusparseDestroyDnMat(mat_dense));

    CUDA_CALL(cudaDeviceSynchronize());
    cout << "  [GPU] sparse matrix => dense matrix \n";
}

//cublasSgemm->cublasGemmEx
void
denseSgemm(cublasHandle_t handle, float *gpu_src, float *gpu_dst, int n) {
    cudaDataType Atype = CUDA_R_32F;
    cudaDataType Btype = CUDA_R_32F;
    cudaDataType Ctype = CUDA_R_32F;
    cublasComputeType_t computeType = CUBLAS_COMPUTE_32F;

    CUBLAS_CALL(cublasGemmEx(handle,
                             CUBLAS_OP_N, CUBLAS_OP_N,
                             n, n, n,
                             &alpha,
                             gpu_src, Atype, n,
                             gpu_src, Btype, n,
                             &beta,
                             gpu_dst, Ctype, n,
                             computeType,
                             CUBLAS_GEMM_DEFAULT));
    CUDA_CALL(cudaDeviceSynchronize());
    cout<< "  [GPU] dense gemm\n";
}

void
denseStrmm(cublasHandle_t handle, float *gpu_src, float *gpu_dst, int n) {
  CUBLAS_CALL(cublasStrmm(
      handle,
      CUBLAS_SIDE_LEFT,
      CUBLAS_FILL_MODE_UPPER,
      CUBLAS_OP_N,
      CUBLAS_DIAG_UNIT,
      n, n,
      &alpha,
      gpu_src, n,
      gpu_src, n,
      gpu_dst, n));
  CUDA_CALL(cudaDeviceSynchronize());
  cout<< "  [GPU] dense trmm\n";
}


int
sparseSparseMM(cusparseHandle_t handle, cusparseMatDescr_t descr_old,
               float* &csr_val, int* &csr_rowptr, int* &csr_colind,
               int nnz, int n) {
    
    cusparseSpMatDescr_t matA, matB, matC;
    cusparseSpGEMMDescr_t spgemmDesc;

    cudaDataType      computeType = CUDA_R_32F;
    cusparseIndexType_t indexType   = CUSPARSE_INDEX_32I;
    cusparseIndexBase_t indexBase   = cusparseGetMatIndexBase(descr_old);

    const float spgemm_alpha = 1.0f;
    const float spgemm_beta  = 0.0f;

    CUSPARSE_CALL(cusparseSpGEMM_createDescr(&spgemmDesc));

    CUSPARSE_CALL(cusparseCreateCsr(&matA, n, n, nnz, csr_rowptr, csr_colind, csr_val,
                                    indexType, indexType, indexBase, computeType));
    CUSPARSE_CALL(cusparseCreateCsr(&matB, n, n, nnz, csr_rowptr, csr_colind, csr_val,
                                    indexType, indexType, indexBase, computeType));
    CUSPARSE_CALL(cusparseCreateCsr(&matC, n, n, 0, NULL, NULL, NULL,
                                    indexType, indexType, indexBase, computeType));

    size_t bufferSize1 = 0, bufferSize2 = 0;
    void* dBuffer1 = NULL, *dBuffer2 = NULL;
    
    // SpGEMM Phase 1: Work Estimation
    CUSPARSE_CALL(cusparseSpGEMM_workEstimation(handle, CUSPARSE_OPERATION_NON_TRANSPOSE, CUSPARSE_OPERATION_NON_TRANSPOSE,
                                                &spgemm_alpha, matA, matB, &spgemm_beta, matC, computeType, 
                                                CUSPARSE_SPGEMM_DEFAULT, spgemmDesc, &bufferSize1, NULL));
    if (bufferSize1 > 0) { CUDA_CALL(cudaMalloc(&dBuffer1, bufferSize1)); }
    
    CUSPARSE_CALL(cusparseSpGEMM_workEstimation(handle, CUSPARSE_OPERATION_NON_TRANSPOSE, CUSPARSE_OPERATION_NON_TRANSPOSE,
                                                &spgemm_alpha, matA, matB, &spgemm_beta, matC, computeType, 
                                                CUSPARSE_SPGEMM_DEFAULT, spgemmDesc, &bufferSize1, dBuffer1));

    int64_t nnz_C;
    int64_t rows_C, cols_C;
    int* csr_rowptr_C;
    int* csr_colind_C;
    float* csr_val_C;

    cusparseIndexType_t rowOffsetsType;
    cusparseIndexType_t colIndType;
    cusparseIndexBase_t idxBase;
    cudaDataType        valueType;
    
    //cusparseSpMatGetAttribute->cusparseCsrGet
    CUSPARSE_CALL(cusparseCsrGet(matC, &rows_C, &cols_C, &nnz_C, 
                                 (void**)&csr_rowptr_C,
                                 (void**)&csr_colind_C,
                                 (void**)&csr_val_C, &rowOffsetsType, &colIndType, &idxBase, &valueType));

    CUDA_CALL(cudaMalloc(&csr_rowptr_C, sizeof(int)   * (rows_C + 1)));
    CUDA_CALL(cudaMalloc(&csr_colind_C, sizeof(int)   * nnz_C));
    CUDA_CALL(cudaMalloc(&csr_val_C,    sizeof(float) * nnz_C));
    CUSPARSE_CALL(cusparseCsrSetPointers(matC, csr_rowptr_C, csr_colind_C, csr_val_C));
    
    // SpGEMM Phase 2: Compute
    CUSPARSE_CALL(cusparseSpGEMM_compute(handle, CUSPARSE_OPERATION_NON_TRANSPOSE, CUSPARSE_OPERATION_NON_TRANSPOSE,
                                         &spgemm_alpha, matA, matB, &spgemm_beta, matC, computeType, 
                                         CUSPARSE_SPGEMM_DEFAULT, spgemmDesc, &bufferSize2, NULL));
    if (bufferSize2 > 0) { CUDA_CALL(cudaMalloc(&dBuffer2, bufferSize2)); }

    CUSPARSE_CALL(cusparseSpGEMM_compute(handle, CUSPARSE_OPERATION_NON_TRANSPOSE, CUSPARSE_OPERATION_NON_TRANSPOSE,
                                         &spgemm_alpha, matA, matB, &spgemm_beta, matC, computeType, 
                                         CUSPARSE_SPGEMM_DEFAULT, spgemmDesc, &bufferSize2, dBuffer2));

    CUDA_CALL(cudaFree(csr_rowptr));
    CUDA_CALL(cudaFree(csr_val));
    CUDA_CALL(cudaFree(csr_colind));
    csr_rowptr = csr_rowptr_C;
    csr_val    = csr_val_C;
    csr_colind = csr_colind_C;

    if (bufferSize1 > 0) { CUDA_CALL(cudaFree(dBuffer1)); }
    if (bufferSize2 > 0) { CUDA_CALL(cudaFree(dBuffer2)); }
    CUSPARSE_CALL(cusparseDestroySpMat(matA));
    CUSPARSE_CALL(cusparseDestroySpMat(matB));
    CUSPARSE_CALL(cusparseDestroySpMat(matC));
    CUSPARSE_CALL(cusparseSpGEMM_destroyDescr(spgemmDesc));
    
    cout << "  [GPU] sparse-sparse mm\n";
    
    return (int)nnz_C;
}


int
dense2sparse(cusparseHandle_t handle, cusparseMatDescr_t descr,
  int *nnz_row, float *dense_m,
  float *csr_val, int *csr_rowptr, int *csr_colind,
  int n) {
  int nnz_total;
  // count number of non-zero element
  countNNZ(handle, descr, nnz_row, nnz_total, dense_m, n);
  if (nnz_total > MAX_NNZ) {
    cout << "[INFO] too many non-zeros(" << nnz_total << "), maximum " << MAX_NNZ << "\n";
    cout << "[INFO] stop using sparse\n";
    //assert(false);
  } else {
    // init the sparse matrix
  cudaDense2sparse(handle, descr, dense_m, nnz_row, csr_val,
        csr_rowptr, csr_colind, nnz_total, n);
    cout << "[INFO] matrix is sparse, using sparse\n";
  }
  return nnz_total;
}

void regulateCPU(float* a, int size) {
  for (int i=0; i<size; i++) {
    a[i] = 2 * (a[i] != 0);
  }
}

__global__
void regulateGPU(float *a, int length) {
  int index = (threadIdx.x + blockIdx.x * blockDim.x) * REGULATE_BATCH;
  //printf("block %d, thread %d, index[%d] => [%f]\n", blockIdx.x, threadIdx.x, index, a[index]);
  for (int i=0; i<REGULATE_BATCH; i++) {
    if (index+i < length) {
      a[index + i] = 2 * (a[index + i] != 0);
    }
  }
}

void regulate(float *gpu_m, int length, float *cpu_m) {
#ifdef REGULATE_GPU
  if (length == 0) {
    return;
  }
  int num_blocks = ceil((double)length/THREADS_PER_BLOCK/REGULATE_BATCH);
  regulateGPU<<<num_blocks, THREADS_PER_BLOCK>>>(gpu_m, length);
  auto e = cudaGetLastError();
  if ( cudaSuccess !=  e ) {
    cout << "CUDA: " << cudaGetErrorString(e) << endl;
    assert(false);
  }
  CUDA_CALL(cudaDeviceSynchronize());
#else
  CUDA_CALL(cudaMemcpy(cpu_m, gpu_m, length*sizeof(float), cudaMemcpyDeviceToHost));
  regulateCPU(cpu_m, length);
  CUDA_CALL(cudaMemcpy(gpu_m, cpu_m, length*sizeof(float), cudaMemcpyHostToDevice));
#endif
}


__device__ int matrix_diff;

__global__
void initEarlyTermination() {
  matrix_diff = 0;
}

__global__
void compareGPU(float *gpu_m_1, float *gpu_m_2, int length) {
  int index = (threadIdx.x + blockIdx.x * blockDim.x) * REGULATE_BATCH;
  for (int i=0; i<REGULATE_BATCH; i++) {
    if (index+i < length) {
      if ( (gpu_m_1[index + i] != 0) != (gpu_m_2[index + i] != 0) ) {
        matrix_diff = 1;
      }
    }
  }
}

bool earlyTermination(float *gpu_m_1, float *gpu_m_2, int n, int length) {
  #ifdef OPT_EARLY_TERMINATION
      if (n < MAGIC_EARLY_TERMINATION_THRESHOLD) {
          return false;
      }
  
      initEarlyTermination<<<1,1>>>();
      auto e = cudaGetLastError();
      if (cudaSuccess != e) {
          cout << "CUDA: " << cudaGetErrorString(e) << endl;
          assert(false);
      }
  
      int num_blocks = ceil((double)length/THREADS_PER_BLOCK/REGULATE_BATCH);
      compareGPU<<<num_blocks, THREADS_PER_BLOCK>>>(gpu_m_1, gpu_m_2, length);
      e = cudaGetLastError();
      if (cudaSuccess != e) {
          cout << "CUDA: " << cudaGetErrorString(e) << endl;
          assert(false);
      }
      CUDA_CALL(cudaDeviceSynchronize());
  
      int diff_h;
      CUDA_CALL(cudaMemcpyFromSymbol(&diff_h, matrix_diff, sizeof(int), 0, cudaMemcpyDeviceToHost));
      
      return diff_h == 0;
  #else
      return false;
  #endif
}



void swapSrcDst(float *&gpu_src, float *&gpu_dst) {
  // swap
  float *tmp = gpu_src;
  gpu_src = gpu_dst;
  gpu_dst = tmp;
}

// ====== exposed functions =====

JNIEXPORT void JNICALL Java_gpu_GPUmm_init(JNIEnv *env, jclass cls) {
  int n = MAX_N;
  int nnz_total = MAX_NNZ;

  // (1) allocate and initialize GPU matrix memory
  CUBLAS_CALL(cublasCreate(&handle_c));
  CUDA_CALL(cudaMalloc(&gpu_m, n*n*sizeof(float)));
  CUDA_CALL(cudaMalloc(&gpu_m2, n*n*sizeof(float)));

  // (2) decide whether use sparse matrix
  //     if so, allocate sparse matrix memory
  CUSPARSE_CALL(cusparseCreate(&handle_s));
  CUSPARSE_CALL(cusparseCreate(&handle_ss));
  CUSPARSE_CALL(cusparseSetPointerMode(handle_ss, CUSPARSE_POINTER_MODE_HOST));
  CUSPARSE_CALL(cusparseCreateMatDescr(&descr));
  CUSPARSE_CALL(cusparseSetMatIndexBase(descr, CUSPARSE_INDEX_BASE_ZERO));

  CUDA_CALL(cudaMalloc(&gpu_nnz_row, sizeof(int) * n));
  CUDA_CALL(cudaMalloc(&gpu_csr_val, sizeof(float) * nnz_total)  );
  CUDA_CALL(cudaMalloc(&gpu_csr_rowptr, sizeof(int) * (n+1) ) ) ;
  CUDA_CALL(cudaMalloc(&gpu_csr_colind, sizeof(int) * nnz_total) ) ;
}

JNIEXPORT void JNICALL Java_gpu_GPUmm_destroy(JNIEnv *env, jclass cls) {
  CUSPARSE_CALL(cusparseDestroyMatDescr(descr));
  CUSPARSE_CALL(cusparseDestroy(handle_s));
  CUSPARSE_CALL(cusparseDestroy(handle_ss));
  CUBLAS_CALL(cublasDestroy(handle_c));

  CUDA_CALL(cudaFree(gpu_m));
  CUDA_CALL(cudaFree(gpu_m2));
  CUDA_CALL(cudaFree(gpu_nnz_row));
  CUDA_CALL(cudaFree(gpu_csr_val));
  CUDA_CALL(cudaFree(gpu_csr_rowptr));
  CUDA_CALL(cudaFree(gpu_csr_colind));
}


void dumpM(float* a, int n);
/*
 * Connect src_list -> dst_list and update the reachability matrix
 */
JNIEXPORT void JNICALL Java_gpu_GPUmm_connect(JNIEnv *env, jclass cls,
  jfloatArray fb, jintArray src_list, jintArray dst_list, jint jn)
{
int n = (int) jn;
int len = (int) env->GetArrayLength(src_list);
int m_size = sizeof(float) * n * len;
int src_inds[len], dst_inds[len];

jint *jsrc_inds = env->GetIntArrayElements(src_list, 0);
jint *jdst_inds = env->GetIntArrayElements(dst_list, 0);
for (int i=0; i<len; i++) {
  src_inds[i] = jsrc_inds[i];
  dst_inds[i] = jdst_inds[i];
}

float *cpu_src_matrix, *cpu_dst_matrix, *gpu_src_matrix, *gpu_dst_matrix;
cpu_src_matrix = (float*) malloc(m_size);
cpu_dst_matrix = (float*) malloc(m_size);
CUDA_CALL(cudaMalloc(&gpu_src_matrix, m_size));
CUDA_CALL(cudaMalloc(&gpu_dst_matrix, m_size));

float *cpu_matrix = (float*) env->GetPrimitiveArrayCritical(fb, 0);
if (cpu_matrix == NULL) {
  cout << "cpu_matrix is NULL!!!\n";
  return;
}

for (int i=0; i<len; i++) {
  int src = src_inds[i];
  int dst = dst_inds[i];
  cpu_matrix[dst*n + src] = 1;
  for (int j=0; j<n; j++) {
    if (cpu_matrix[j*n + dst] != 0) {
      cpu_matrix[j*n + src] = 1;
    }
    if (cpu_matrix[src*n + j] != 0) {
      cpu_matrix[dst*n + j] = 1;
    }
  }
}

for (int i=0; i<len; i++) {
  int src = src_inds[i];
  int dst = dst_inds[i];
  for (int j=0; j<n; j++) {
    cpu_src_matrix[i*n + j] = cpu_matrix[src*n + j];
  }
  for (int j=0; j<n; j++) {
    cpu_dst_matrix[j*len + i] = cpu_matrix[j*n + dst];
  }
}

CUDA_CALL(cudaMemcpy(gpu_src_matrix, cpu_src_matrix, m_size, cudaMemcpyHostToDevice));
CUDA_CALL(cudaMemcpy(gpu_dst_matrix, cpu_dst_matrix, m_size, cudaMemcpyHostToDevice));
CUDA_CALL(cudaMemcpy(gpu_m, cpu_matrix, n*n*sizeof(float), cudaMemcpyHostToDevice));

const float m_beta = 1.0;

CUBLAS_CALL(cublasGemmEx(handle_c,
                         CUBLAS_OP_N, CUBLAS_OP_N,
                         n, n, len,
                         &alpha,
                         gpu_src_matrix, CUDA_R_32F, n,
                         gpu_dst_matrix, CUDA_R_32F, len,
                         &m_beta,
                         gpu_m,          CUDA_R_32F, n,
                         CUBLAS_COMPUTE_32F,
                         CUBLAS_GEMM_DEFAULT));

CUDA_CALL(cudaDeviceSynchronize());
CUDA_CALL(cudaMemcpy(cpu_matrix, gpu_m, n*n*sizeof(float), cudaMemcpyDeviceToHost));
regulateCPU(cpu_matrix, n*n);
env->ReleasePrimitiveArrayCritical(fb, cpu_matrix, 0);

CUDA_CALL(cudaFree(gpu_src_matrix));
CUDA_CALL(cudaFree(gpu_dst_matrix));
free(cpu_src_matrix);
free(cpu_dst_matrix);
}


void dumpPartM(float* a, int printn, int n);

int
power(float *cpu_m, int n, bool fresh) {
  if (n > MAX_N) {
    cout << "ERROR, too large a 'n'(" << n << ") size, maximum " << MAX_N << "\n";
    assert(false);
  }
  cout << "[INFO] n=" << n << "\n";

  CUDA_CALL(cudaMemcpy(gpu_m, cpu_m, n*n*sizeof(float), cudaMemcpyHostToDevice));

  int nnz = fresh ? dense2sparse(handle_s, descr, gpu_nnz_row, gpu_m,
                    gpu_csr_val, gpu_csr_rowptr, gpu_csr_colind, n) :
                  MAX_NNZ;

  timeval start, end;
  gettimeofday(&start, 0);
  int prev_nnz = -1;

  int dense_m = 1;
  bool used_sparse = false;
  while(fresh && staySparse(n, nnz)) {
    if (nnz == prev_nnz) {
      cout << "[INFO] Sparse matrix reached a fixed point. Exiting loop." << endl;
      break;
    }
    prev_nnz = nnz;

    nnz = sparseSparseMM(handle_ss, descr,
                         gpu_csr_val, gpu_csr_rowptr, gpu_csr_colind, nnz, n);
    regulate(gpu_csr_val, nnz, cpu_m);
    dense_m*= 2;
    used_sparse = true;
  }

  if (used_sparse) {
    sparse2dense(handle_s, descr,
                 gpu_csr_val, gpu_csr_rowptr, gpu_csr_colind,
                 gpu_m, n);
    CUDA_CALL(cudaFree(gpu_csr_val));
    CUDA_CALL(cudaFree(gpu_csr_rowptr));
    CUDA_CALL(cudaFree(gpu_csr_colind));
    CUDA_CALL(cudaMalloc(&gpu_csr_val, sizeof(float) * MAX_NNZ));
    CUDA_CALL(cudaMalloc(&gpu_csr_rowptr, sizeof(int) * (MAX_N + 1)));
    CUDA_CALL(cudaMalloc(&gpu_csr_colind, sizeof(int) * MAX_NNZ));
  }

  float *gpu_src = gpu_m;
  float *gpu_dst = gpu_m2;

  while(dense_m < n) {
#ifdef OPT_TRIANGULAR_MM
    denseStrmm(handle_c, gpu_src, gpu_dst, n);
#else
    denseSgemm(handle_c, gpu_src, gpu_dst, n);
#endif
    dense_m *= 2;
    regulate(gpu_dst, n*n, cpu_m);
    // 【修正済】`n`を渡すように修正
    if(earlyTermination(gpu_src, gpu_dst, n, n*n)) {
      cout << "Early termination, dense_m=" << dense_m << ", n=" << n << "\n";
      break;
    }
    swapSrcDst(gpu_src, gpu_dst);
  }

  gettimeofday(&end, 0);
  double milli = (end.tv_sec - start.tv_sec) * 1000 + (end.tv_usec - start.tv_usec) * .001;

  CUDA_CALL(cudaMemcpy(cpu_m, gpu_src, n*n*sizeof(float), cudaMemcpyDeviceToHost));
  cout << "DONE, DM^" << dense_m << ", time = " << milli << "ms\n";

  return 0;
}



JNIEXPORT void JNICALL Java_gpu_GPUmm_power (JNIEnv *env, jclass cls, jfloatArray jarr, jint jn, jboolean jfresh) {
  int n = (int) jn;
  bool fresh = (bool) jfresh;
  float *matrix = (float*) env->GetPrimitiveArrayCritical(jarr, 0);
  //float *matrix = (float*) env->GetFloatArrayElements(jarr, 0);
  if (matrix == NULL) {
    cout << "NULL!!!\n";
    return;
  }

  power(matrix, n, fresh);

  /*
  // debug code
  ofstream outf;
  outf.open("/tmp/mmresult");
  for(int i=0; i<n*n; i++) {
    if (matrix[i] != 0) {
      outf << "1";
    } else {
      outf << "0";
    }
  }
  outf.close();
  */

  env->ReleasePrimitiveArrayCritical(jarr, matrix, 0);
  //env->ReleaseFloatArrayElements(jarr, matrix, 0);
}


int
selfmm(float *cpu_m, int n) {
  if (n > MAX_N) {
    cout << "ERROR, selfmm, too large a 'n'(" << n << ") size, maximum " << MAX_N << "\n";
    assert(false);
  }
  cout << "[INFO] selfmm, n=" << n << "\n";

  float *gpu_src = gpu_m;
  float *gpu_dst = gpu_m2;

  CUDA_CALL(cudaMemcpy(gpu_src, cpu_m, n*n*sizeof(float), cudaMemcpyHostToDevice));

  timeval start, end;
  gettimeofday(&start, 0);
#ifdef OPT_TRIANGULAR_MM
        denseStrmm(handle_c, gpu_src, gpu_dst, n);
#else
        denseSgemm(handle_c, gpu_src, gpu_dst, n);
#endif
  gettimeofday(&end, 0);
  double milli = (end.tv_sec - start.tv_sec) * 1000 + (end.tv_usec - start.tv_usec) * .001;
  CUDA_CALL(cudaMemcpy(cpu_m, gpu_dst, n*n*sizeof(float), cudaMemcpyDeviceToHost));
  cout << "DONE, selfmm, time = " << milli << "ms\n";

  return 0;
}


JNIEXPORT void JNICALL Java_gpu_GPUmm_selfmm(JNIEnv *env, jclass cls, jfloatArray jarr, jint jn) {
  int n = (int) jn;
  float *matrix = (float*) env->GetPrimitiveArrayCritical(jarr, 0);
  //float *matrix = (float*) env->GetFloatArrayElements(jarr, 0);
  if (matrix == NULL) {
    cout << "NULL!!!\n";
    return;
  }

  selfmm(matrix, n);

  env->ReleasePrimitiveArrayCritical(jarr, matrix, 0);
  //env->ReleaseFloatArrayElements(jarr, matrix, 0);
}

void dumpM(float* a, int n) {
  cout << "=== n=" << n <<"\n";
  for (int i=0; i<n; i++) {
    for (int j=0; j<n; j++) {
      cout << a[i*n+j] << "  ";
    }
    cout << "\n";
  }
  cout << "===\n";
}

void dumpPartM(float* a, int printn, int n) {
  cout << "=== n=" << n <<"\n";
  for (int i=n/2; i<n/2+printn; i++) {
    for (int j=n/2; j<n/2+printn; j++) {
      cout << a[i*n+j] << "  ";
    }
    cout << "\n";
  }
  cout << "===\n";
}
