/*
 * Copyright (c) 2019-2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include <cuml/tree/flatnode.h>
#include <common/grid_sync.cuh>
#include <cstdio>
#include <cuml/tree/decisiontree.hpp>
#include <raft/cuda_utils.cuh>
#include "input.cuh"
#include "kernels.cuh"
#include "metrics.cuh"
#include "node.cuh"
#include "split.cuh"

#include <common/nvtx.hpp>

namespace ML {
namespace DecisionTree {

/**
 * Internal struct used to do all the heavy-lifting required for tree building
 *
 * @note This struct does NOT own any of the underlying device/host pointers.
 *       They all must explicitly be allocated by the caller and passed to it.
 */
template <typename ObjectiveT>
struct Builder {
  typedef typename ObjectiveT::DataT DataT;
  typedef typename ObjectiveT::LabelT LabelT;
  typedef typename ObjectiveT::IdxT IdxT;
  typedef typename ObjectiveT::BinT BinT;
  typedef Node<DataT, LabelT, IdxT> NodeT;
  typedef Split<DataT, IdxT> SplitT;
  typedef Input<DataT, LabelT, IdxT> InputT;

  /** default threads per block for most kernels in here */
  static constexpr int TPB_DEFAULT = 256;
  /** threads per block for the nodeSplitKernel */
  static constexpr int TPB_SPLIT = 128;
  /** DT params */
  DecisionTreeParams params;
  /** input dataset */
  InputT input;

  /** max nodes that we can create */
  IdxT maxNodes;
  /** total number of histogram bins (classification only) */
  IdxT nHistBins;
  /** total number of prediction counts (regression only) */
  IdxT nPredCounts;
  /** size of block-sync workspace (regression + MAE only) */
  size_t block_sync_size;

  /** Tree index */
  IdxT treeid;
  /** Seed used for randomization */
  uint64_t seed;
  /** number of nodes created in the current batch */
  IdxT* n_nodes;
  /** class histograms (classification only) */
  BinT* hist;
  /** threadblock arrival count */
  int* done_count;
  /** mutex array used for atomically updating best split */
  int* mutex;
  /** used for syncing across blocks in a kernel (regression + MAE only) */
  char* block_sync;
  /** number of leaves created so far */
  IdxT* n_leaves;
  /** max depth reached so far */
  IdxT* n_depth;
  /** best splits for the current batch of nodes */
  SplitT* splits;
  /** current batch of nodes */
  NodeT* curr_nodes;
  /** next batch of nodes */
  NodeT* next_nodes;

  /** host copy of the number of new nodes in current branch */
  IdxT* h_n_nodes;
  /** total number of nodes created so far */
  IdxT h_total_nodes;
  /** range of the currently worked upon nodes */
  IdxT node_start, node_end;
  /** number of blocks used to parallelize column-wise computations. */
  int n_blks_for_cols = 10;
  /** Memory alignment value */
  const size_t alignValue = 512;

  /** checks if this struct is being used for classification or regression */
  static constexpr bool isRegression() {
    return std::is_same<DataT, LabelT>::value;
  }

  /**
   * @brief Assigns number of blocks used to parallelize row-wise computations to maximize occupacy
   *
   * @param[out] n_blks_for_rows    Appropriate blocks for rows (gridDim.x)
   *                                that maximizes occupancy
   * @param[in] gridDimy            number of blocks assigned in the y-dimension (n_blks_for_cols)
   * @param[in] func                Kernel function; needed by the occupancy calculator for finding
   *                                maximum active blocks per multiprocessor
   * @param[in] blockSize           Threads per Block, passed to cuda occupancy calculator API
   * @param[in] dynamic_smem_size   dynamic shared memory size, passed to cuda occupancy calculator API
   * @param[in] gridDimz            Number of blocks along the z-dimension, based
   *                                on the concurrent nodes of tree available to be processed.
  */
  int n_blks_for_rows(const int gridDimy, const void* func, const int blockSize,
                      const size_t dynamic_smem_size, const int gridDimz) {
    int devid;
    CUDA_CHECK(cudaGetDevice(&devid));
    int mpcount;
    CUDA_CHECK(
      cudaDeviceGetAttribute(&mpcount, cudaDevAttrMultiProcessorCount, devid));
    int maxblks;
    // get expected max blocks per multiprocessor
    CUDA_CHECK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(
      &maxblks, func, blockSize, dynamic_smem_size));
    // get the total number of blocks
    int n_blks = maxblks * mpcount;
    // return appropriate number of blocks in x-dimension
    return raft::ceildiv(n_blks, gridDimy * gridDimz);
  }

  size_t calculateAlignedBytes(const size_t actualSize) {
    return raft::alignTo(actualSize, alignValue);
  }

  /**
   * @brief Computes workspace size needed for the current computation
   *
   * @param[out] d_wsize    (in B) of the device workspace to be allocated
   * @param[out] h_wsize    (in B) of the host workspace to be allocated
   * @param[in]  p the      input params
   * @param[in]  data       input dataset [on device] [col-major]
   *                        [dim = totalRows x totalCols]
   * @param[in]  labels     output label for each row in the dataset
   *                        [len = totalRows] [on device].
   * @param[in] totalRows   total rows in the dataset
   * @param[in] totalCols   total cols in the dataset
   * @param[in] sampledRows number of rows sampled in the dataset
   * @param[in] sampledCols number of cols sampled in the dataset
   * @param[in] rowids      sampled row ids [on device] [len = sampledRows]
   * @param[in] colids      sampled col ids [on device] [len = sampledCols]
   * @param[in] nclasses    number of output classes (only for classification)
   * @param[in] quantiles   histogram/quantile bins of the input dataset, for
   *                        each of its column. Pass a nullptr if this needs to
   *                        be computed fresh. [on device] [col-major]
   *                        [dim = nbins x sampledCols]
   */
  void workspaceSize(size_t& d_wsize, size_t& h_wsize, IdxT treeid,
                     uint64_t seed, const DecisionTreeParams& p,
                     const DataT* data, const LabelT* labels, IdxT totalRows,
                     IdxT totalCols, IdxT sampledRows, IdxT sampledCols,
                     IdxT* rowids, IdxT nclasses, const DataT* quantiles) {
    ML::PUSH_RANGE(
      "Builder::workspaceSize @builder_base.cuh [batched-levelalgo]");
    ASSERT(quantiles != nullptr,
           "Currently quantiles need to be computed before this call!");
    params = p;
    this->treeid = treeid;
    this->seed = seed;
    n_blks_for_cols = std::min(sampledCols, n_blks_for_cols);
    input.data = data;
    input.labels = labels;
    input.M = totalRows;
    input.N = totalCols;
    input.nSampledRows = sampledRows;
    input.nSampledCols = sampledCols;
    input.rowids = rowids;
    input.nclasses = nclasses;
    ASSERT(nclasses >= 1, "nclasses should be at least 1");
    input.quantiles = quantiles;
    auto max_batch = params.max_batch_size;
    auto n_col_blks = n_blks_for_cols;
    nHistBins = max_batch * (1 + params.n_bins) * n_col_blks * nclasses;
    if (params.max_depth < 13) {
      // Start with allocation for a dense tree for depth < 13
      maxNodes = pow(2, (params.max_depth + 1)) - 1;
    } else {
      // Start with fixed size allocation for depth >= 13
      maxNodes = 8191;
    }

    block_sync_size = 0;
    d_wsize = 0;
    d_wsize += calculateAlignedBytes(sizeof(IdxT));              // n_nodes
    d_wsize += calculateAlignedBytes(sizeof(BinT) * nHistBins);  // hist
    d_wsize += calculateAlignedBytes(sizeof(int) * max_batch *
                                     n_col_blks);                  // done_count
    d_wsize += calculateAlignedBytes(sizeof(int) * max_batch);     // mutex
    d_wsize += calculateAlignedBytes(block_sync_size);             // block_sync
    d_wsize += calculateAlignedBytes(sizeof(IdxT));                // n_leaves
    d_wsize += calculateAlignedBytes(sizeof(IdxT));                // n_depth
    d_wsize += calculateAlignedBytes(sizeof(SplitT) * max_batch);  // splits
    d_wsize += calculateAlignedBytes(sizeof(NodeT) * max_batch);   // curr_nodes
    d_wsize +=
      calculateAlignedBytes(sizeof(NodeT) * 2 * max_batch);  // next_nodes
    // all nodes in the tree
    h_wsize = calculateAlignedBytes(sizeof(IdxT));  // h_n_nodes
    ML::POP_RANGE();
  }

  /**
   * @brief assign workspace to the current state
   *
   * @param[in] d_wspace device buffer allocated by the user for the workspace.
   *                     Its size should be atleast workspaceSize()
   * @param[in] h_wspace pinned host buffer needed to store the learned nodes
   */
  void assignWorkspace(char* d_wspace, char* h_wspace) {
    ML::PUSH_RANGE(
      "Builder::assignWorkspace @builder_base.cuh [batched-levelalgo]");
    auto max_batch = params.max_batch_size;
    auto n_col_blks = n_blks_for_cols;
    // device
    n_nodes = reinterpret_cast<IdxT*>(d_wspace);
    d_wspace += calculateAlignedBytes(sizeof(IdxT));
    hist = reinterpret_cast<BinT*>(d_wspace);
    d_wspace += calculateAlignedBytes(sizeof(BinT) * nHistBins);
    done_count = reinterpret_cast<int*>(d_wspace);
    d_wspace += calculateAlignedBytes(sizeof(int) * max_batch * n_col_blks);
    mutex = reinterpret_cast<int*>(d_wspace);
    d_wspace += calculateAlignedBytes(sizeof(int) * max_batch);
    block_sync = reinterpret_cast<char*>(d_wspace);
    d_wspace += calculateAlignedBytes(block_sync_size);
    n_leaves = reinterpret_cast<IdxT*>(d_wspace);
    d_wspace += calculateAlignedBytes(sizeof(IdxT));
    n_depth = reinterpret_cast<IdxT*>(d_wspace);
    d_wspace += calculateAlignedBytes(sizeof(IdxT));
    splits = reinterpret_cast<SplitT*>(d_wspace);
    d_wspace += calculateAlignedBytes(sizeof(SplitT) * max_batch);
    curr_nodes = reinterpret_cast<NodeT*>(d_wspace);
    d_wspace += calculateAlignedBytes(sizeof(NodeT) * max_batch);
    next_nodes = reinterpret_cast<NodeT*>(d_wspace);
    // host
    h_n_nodes = reinterpret_cast<IdxT*>(h_wspace);
    ML::POP_RANGE();
  }

  /**
   * @brief Main training method. To be called only after `assignWorkspace()`
   *
   * @param[out] h_nodes    list of nodes (must be allocated using
   *                        cudaMallocHost!)
   * @param[out] num_leaves number of leaves created in the tree
   * @param[out] depth      max depth of the built tree
   * @param[in]  s          cuda steam
   */
  void train(std::vector<Node<DataT, LabelT, IdxT>>& h_nodes, IdxT& num_leaves,
             IdxT& depth, cudaStream_t s) {
    ML::PUSH_RANGE("Builder::train @builder_base.cuh [batched-levelalgo]");
    init(h_nodes, s);
    while (true) {
      IdxT new_nodes = doSplit(h_nodes, s);
      h_total_nodes += new_nodes;
      if (new_nodes == 0 && isOver()) break;
      updateNodeRange();
    }
    raft::update_host(&num_leaves, n_leaves, 1, s);
    raft::update_host(&depth, n_depth, 1, s);
    ML::POP_RANGE();
  }

  /**
   * @brief Computes the smem size (in B) needed for `nodeSplitKernel`
   *
   * @param[in] b         builder object
   *
   * @return the smem size (in B)
   */
  size_t nodeSplitSmemSize() {
    return std::max(2 * sizeof(IdxT) * TPB_SPLIT, sizeof(int) * input.nclasses);
  }

 private:
  /**
   * @brief Initialize buffers and state
   *
   * @param[out] h_nodes list of nodes (must be allocated using cudaMallocHost!)
   * @param[in]  s       cuda stream
   */
  void init(std::vector<Node<DataT, LabelT, IdxT>>& h_nodes, cudaStream_t s) {
    *h_n_nodes = 0;
    auto max_batch = params.max_batch_size;
    auto n_col_blks = n_blks_for_cols;
    CUDA_CHECK(
      cudaMemsetAsync(done_count, 0, sizeof(int) * max_batch * n_col_blks, s));
    CUDA_CHECK(cudaMemsetAsync(mutex, 0, sizeof(int) * max_batch, s));
    CUDA_CHECK(cudaMemsetAsync(n_leaves, 0, sizeof(IdxT), s));
    CUDA_CHECK(cudaMemsetAsync(n_depth, 0, sizeof(IdxT), s));
    if (isRegression()) {
      CUDA_CHECK(
        cudaMemsetAsync(block_sync, 0, sizeof(char) * block_sync_size, s));
    }
    node_start = 0;
    node_end = h_total_nodes = 1;  // start with root node
    h_nodes.resize(1);
    h_nodes[0].initSpNode();
    h_nodes[0].start = 0;
    h_nodes[0].count = input.nSampledRows;
    h_nodes[0].depth = 0;
    h_nodes[0].info.unique_id = 0;
  }

  /** check whether any more nodes need to be processed or not */
  bool isOver() const { return node_end == h_total_nodes; }

  /**
   * @brief After the current batch is finished processing, update the range
   *        of nodes to be worked upon in the next batch
   */
  void updateNodeRange() {
    node_start = node_end;
    auto nodes_remaining = h_total_nodes - node_end;
    node_end = std::min(nodes_remaining, params.max_batch_size) + node_end;
  }

  /**
   * @brief Computes best split across all nodes in the current batch and splits
   *        the nodes accordingly
   *
   * @param[out] h_nodes list of nodes (must be allocated using cudaMallocHost!)
   * @param[in]  s cuda stream
   * @return the number of newly created nodes
   */
  IdxT doSplit(std::vector<Node<DataT, LabelT, IdxT>>& h_nodes,
               cudaStream_t s) {
    ML::PUSH_RANGE("Builder::doSplit @bulder_base.cuh [batched-levelalgo]");
    auto batchSize = node_end - node_start;
    // start fresh on the number of *new* nodes created in this batch
    CUDA_CHECK(cudaMemsetAsync(n_nodes, 0, sizeof(IdxT), s));
    initSplit<DataT, IdxT, TPB_DEFAULT>(splits, batchSize, s);

    // get the current set of nodes to be worked upon
    raft::update_device(curr_nodes, h_nodes.data() + node_start, batchSize, s);
    // iterate through a batch of columns (to reduce the memory pressure) and
    // compute the best split at the end
    auto n_col_blks = n_blks_for_cols;
    for (IdxT c = 0; c < input.nSampledCols; c += n_col_blks) {
      computeSplit(c, batchSize, params.split_criterion, s);
      CUDA_CHECK(cudaGetLastError());
    }
    // create child nodes (or make the current ones leaf)
    auto smemSize = nodeSplitSmemSize();
    ML::PUSH_RANGE("nodeSplitKernel @builder_base.cuh [batched-levelalgo]");
    nodeSplitKernel<DataT, LabelT, IdxT, ObjectiveT, TPB_SPLIT>
      <<<batchSize, TPB_SPLIT, smemSize, s>>>(
        params.max_depth, params.min_samples_leaf, params.min_samples_split,
        params.max_leaves, params.min_impurity_decrease, input, curr_nodes,
        next_nodes, n_nodes, splits, n_leaves, h_total_nodes, n_depth);
    CUDA_CHECK(cudaGetLastError());
    ML::POP_RANGE();
    // copy the updated (due to leaf creation) and newly created child nodes
    raft::update_host(h_n_nodes, n_nodes, 1, s);
    CUDA_CHECK(cudaStreamSynchronize(s));
    h_nodes.resize(h_nodes.size() + batchSize + *h_n_nodes);
    raft::update_host(h_nodes.data() + node_start, curr_nodes, batchSize, s);
    raft::update_host(h_nodes.data() + h_total_nodes, next_nodes, *h_n_nodes,
                      s);
    ML::POP_RANGE();
    return *h_n_nodes;
  }
  /**
   * @brief Compute best split for the currently given set of columns
   *
   * @param[in] col       start column id
   * @param[in] batchSize number of nodes to be processed in this call
   * @param[in] splitType split criterion
   * @param[in] s         cuda stream
   */
  void computeSplit(IdxT col, IdxT batchSize, CRITERION splitType,
                    cudaStream_t s) {
    ML::PUSH_RANGE(
      "Builder::computeSplit @builder_base.cuh [batched-levelalgo]");
    auto nbins = params.n_bins;
    auto nclasses = input.nclasses;
    auto colBlks = std::min(n_blks_for_cols, input.nSampledCols - col);

    size_t smemSize1 = (nbins + 1) * nclasses * sizeof(BinT) +  // pdf_shist size
                       nbins * nclasses * sizeof(BinT) +        // cdf_shist size
                       nbins * sizeof(DataT) +                 // sbins size
                       sizeof(int);                            // sDone size
    // Extra room for alignment (see alignPointer in
    // computeSplitClassificationKernel)
    smemSize1 += sizeof(DataT) + 3 * sizeof(int);
    // Calculate the shared memory needed for evalBestSplit
    size_t smemSize2 =
      raft::ceildiv(TPB_DEFAULT, raft::WarpSize) * sizeof(SplitT);
    // Pick the max of two
    size_t smemSize = std::max(smemSize1, smemSize2);
    int n_blks_for_rows = this->n_blks_for_rows(
      colBlks,
      (const void*)
        computeSplitKernel<DataT, LabelT, IdxT, TPB_DEFAULT, ObjectiveT, BinT>,
      TPB_DEFAULT, smemSize, batchSize);
    dim3 grid(n_blks_for_rows, colBlks, batchSize);
    CUDA_CHECK(cudaMemsetAsync(hist, 0, sizeof(BinT) * nHistBins, s));
    ML::PUSH_RANGE(
      "computeSplitClassificationKernel @builder_base.cuh [batched-levelalgo]");
    ObjectiveT objective(input.nclasses, params.min_impurity_decrease,
                         params.min_samples_split);
    computeSplitKernel<DataT, LabelT, IdxT, TPB_DEFAULT>
      <<<grid, TPB_DEFAULT, smemSize, s>>>(
        hist, params.n_bins, params.max_depth, params.min_samples_split,
        params.max_leaves, input, curr_nodes, col, done_count, mutex, n_leaves,
        splits, objective, treeid, seed);
    ML::POP_RANGE();  //computeSplitClassificationKernel
    ML::POP_RANGE();  //Builder::computeSplit
  }
};  // end Builder

}  // namespace DecisionTree
}  // namespace ML
