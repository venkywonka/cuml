/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
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

#include <cuML.hpp>
#include <randomforest/randomforest.hpp>
#include "dataset.h"
#include "harness.h"

namespace ML {
namespace Bench {
namespace rf {

template <typename D>
struct Params : public BlobsParams<D> {
  // algo related
  RF_params p;

  std::string str() const {
    std::ostringstream oss;
    oss << PARAM(p.n_trees) << PARAM(p.bootstrap) << PARAM(p.rows_sample)
        << PARAM(p.n_streams) << PARAM(p.tree_params.max_depth)
        << PARAM(p.tree_params.max_leaves) << PARAM(p.tree_params.max_features)
        << PARAM(p.tree_params.n_bins) << PARAM(p.tree_params.split_algo)
        << PARAM(p.tree_params.min_rows_per_node)
        << PARAM(p.tree_params.bootstrap_features)
        << PARAM(p.tree_params.quantile_per_tree)
        << PARAM(p.tree_params.split_criterion);
    return BlobsParams<D>::str() + oss.str();
  }
};

template <typename D>
struct Run : public Benchmark<Params<D>> {
  void setup() {
    const auto& p = this->getParams();
    CUDA_CHECK(cudaStreamCreate(&stream));
    ///@todo: enable this after PR: https://github.com/rapidsai/cuml/pull/1015
    // handle.reset(new cumlHandle(p.p.n_streams));
    handle.reset(new cumlHandle);
    handle->setStream(stream);
    auto allocator = handle->getDeviceAllocator();
    labels = (int*)allocator->allocate(p.nrows * sizeof(int), stream);
    dataset.blobs(*handle, p.nrows, p.ncols, p.rowMajor, p.nclasses,
                  p.cluster_std, p.shuffle, p.center_box_min, p.center_box_max,
                  p.seed);
    CUDA_CHECK(cudaStreamSynchronize(stream));
  }

  void teardown() {
    const auto& p = this->getParams();
    CUDA_CHECK(cudaStreamSynchronize(stream));
    auto allocator = handle->getDeviceAllocator();
    allocator->deallocate(labels, p.nrows * sizeof(int), stream);
    dataset.deallocate(*handle);
    CUDA_CHECK(cudaStreamSynchronize(stream));
    CUDA_CHECK(cudaStreamDestroy(stream));
  }

  ///@todo: implement
  void metrics(RunInfo& ri) {}

 protected:
  std::shared_ptr<cumlHandle> handle;
  cudaStream_t stream;
  int* labels;
  Dataset<D, int> dataset;
};

struct RunF : public Run<float> {
  void run() {
    const auto& p = this->getParams();
    const auto& h = *handle;
    auto* mPtr = &model;
    mPtr->trees = nullptr;
    ASSERT(!p.rowMajor, "RF only supports col-major inputs");
    fit(h, mPtr, dataset.X, p.nrows, p.ncols, labels, p.nclasses, p.p);
    CUDA_CHECK(cudaStreamSynchronize(handle->getStream()));
  }

 private:
  ML::RandomForestClassifierF model;
};

struct RunD : public Run<double> {
  void run() {
    const auto& p = this->getParams();
    const auto& h = *handle;
    auto* mPtr = &model;
    mPtr->trees = nullptr;
    ASSERT(!p.rowMajor, "RF only supports col-major inputs");
    fit(h, mPtr, dataset.X, p.nrows, p.ncols, labels, p.nclasses, p.p);
    CUDA_CHECK(cudaStreamSynchronize(handle->getStream()));
  }

 private:
  ML::RandomForestClassifierD model;
};

template <typename D>
std::vector<Params<D>> getInputs() {
  struct Triplets {
    int nrows, ncols, nclasses;
  };

  std::vector<Params<D>> out;
  Params<D> p;
  p.rowMajor = false;
  p.cluster_std = (D)10.0;
  p.shuffle = false;
  p.center_box_min = (D)-10.0;
  p.center_box_max = (D)10.0;
  p.seed = 12345ULL;
  p.p.bootstrap = true;
  p.p.rows_sample = 1.f;
  p.p.tree_params.max_leaves = 1 << 20;
  p.p.tree_params.max_features = 1.f;
  p.p.tree_params.min_rows_per_node = 3;
  p.p.tree_params.n_bins = 32;
  p.p.tree_params.bootstrap_features = true;
  p.p.tree_params.quantile_per_tree = false;
  p.p.tree_params.split_algo = 1;
  p.p.tree_params.split_criterion = (ML::CRITERION)0;
  p.p.n_trees = 500;
  std::vector<Triplets> rowcols = {
    {160000, 64, 2},
    {640000, 64, 8},
    // Bosch dataset
    {1184000, 968, 2},
  };
  for (auto& rc : rowcols) {
    // Let's run Bosch only for float type
    if (!std::is_same<D, float>::value && rc.ncols == 968) continue;
    p.nrows = rc.nrows;
    p.ncols = rc.ncols;
    p.nclasses = rc.nclasses;
    for (auto max_depth : std::vector<int>({8, 10})) {
      p.p.tree_params.max_depth = max_depth;
      for (auto streams : std::vector<int>({8, 10})) {
        p.p.n_streams = streams;
        out.push_back(p);
      }
    }
  }
  return out;
}

REGISTER_BENCH(RunF, Params<float>, rfClassifierF, getInputs<float>());
REGISTER_BENCH(RunD, Params<double>, rfClassifierD, getInputs<double>());

}  // end namespace rf
}  // end namespace Bench
}  // end namespace ML
