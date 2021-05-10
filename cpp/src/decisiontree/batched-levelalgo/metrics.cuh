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

#include <common/grid_sync.cuh>
#include <raft/cuda_utils.cuh>
#include "input.cuh"
#include "node.cuh"
#include "split.cuh"

namespace {

template <typename DataT>
class NumericLimits;

template <>
class NumericLimits<float> {
 public:
  static constexpr double kMax = __FLT_MAX__;
};

template <>
class NumericLimits<double> {
 public:
  static constexpr double kMax = __DBL_MAX__;
};

}  // anonymous namespace

namespace ML {
namespace DecisionTree {

template <typename DataT, typename IdxT>
class GiniObjectiveFunction {
  IdxT nclasses;
  DataT min_impurity_decrease;
  IdxT min_samples_leaf;

 public:
  GiniObjectiveFunction(DataT nclasses, IdxT min_impurity_decrease,
                        IdxT min_samples_leaf)
    : nclasses(nclasses),
      min_impurity_decrease(min_impurity_decrease),
      min_samples_leaf(min_samples_leaf) {}

  DI IdxT NumClasses() const { return nclasses; }
  DI Split<DataT, IdxT> Gain(int* shist, DataT* sbins, IdxT col, IdxT len,
                             IdxT nbins) {
    Split<DataT, IdxT> sp;
    constexpr DataT One = DataT(1.0);
    DataT invlen = One / len;
    for (IdxT i = threadIdx.x; i < nbins; i += blockDim.x) {
      int nLeft = 0;
      for (IdxT j = 0; j < nclasses; ++j) {
        nLeft += shist[2 * nbins * j + i];
      }
      auto nRight = len - nLeft;
      auto gain = DataT(0.0);
      // if there aren't enough samples in this split, don't bother!
      if (nLeft < min_samples_leaf || nRight < min_samples_leaf) {
        gain = -NumericLimits<DataT>::kMax;
      } else {
        auto invLeft = One / nLeft;
        auto invRight = One / nRight;
        for (IdxT j = 0; j < nclasses; ++j) {
          int val_i = 0;
          auto lval_i = shist[2 * nbins * j + i];
          auto lval = DataT(lval_i);
          gain += lval * invLeft * lval * invlen;

          val_i += lval_i;
          auto rval_i = shist[2 * nbins * j + nbins + i];
          auto rval = DataT(rval_i);
          gain += rval * invRight * rval * invlen;

          val_i += rval_i;
          auto val = DataT(val_i) * invlen;
          gain -= val * val;
        }
      }
      // if the gain is not "enough", don't bother!
      if (gain <= min_impurity_decrease) {
        gain = -NumericLimits<DataT>::kMax;
      }
      sp.update({sbins[i], col, gain, nLeft});
    }
    return sp;
  }
};

template <typename DataT, typename IdxT>
class EntropyObjectiveFunction {
  IdxT nclasses;
  DataT min_impurity_decrease;
  IdxT min_samples_leaf;

 public:
  EntropyObjectiveFunction(DataT nclasses, IdxT min_impurity_decreas,
                           IdxT min_samples_leafe)
    : nclasses(nclasses),
      min_impurity_decrease(min_impurity_decrease),
      min_samples_leaf(min_samples_leaf) {}
  DI IdxT NumClasses() const { return nclasses; }
  DI Split<DataT, IdxT> Gain(int* shist, DataT* sbins, IdxT col, IdxT len,
                             IdxT nbins) {
    Split<DataT, IdxT> sp;
    constexpr DataT One = DataT(1.0);
    DataT invlen = One / len;
    for (IdxT i = threadIdx.x; i < nbins; i += blockDim.x) {
      int nLeft = 0;
      for (IdxT j = 0; j < nclasses; ++j) {
        nLeft += shist[2 * nbins * j + i];
      }
      auto nRight = len - nLeft;
      auto gain = DataT(0.0);
      // if there aren't enough samples in this split, don't bother!
      if (nLeft < min_samples_leaf || nRight < min_samples_leaf) {
        gain = -NumericLimits<DataT>::kMax;
      } else {
        auto invLeft = One / nLeft;
        auto invRight = One / nRight;
        for (IdxT j = 0; j < nclasses; ++j) {
          int val_i = 0;
          auto lval_i = shist[2 * nbins * j + i];
          if (lval_i != 0) {
            auto lval = DataT(lval_i);
            gain += raft::myLog(lval * invLeft) / raft::myLog(DataT(2)) * lval *
                    invlen;
          }

          val_i += lval_i;
          auto rval_i = shist[2 * nbins * j + nbins + i];
          if (rval_i != 0) {
            auto rval = DataT(rval_i);
            gain += raft::myLog(rval * invRight) / raft::myLog(DataT(2)) *
                    rval * invlen;
          }

          val_i += rval_i;
          if (val_i != 0) {
            auto val = DataT(val_i) * invlen;
            gain -= val * raft::myLog(val) / raft::myLog(DataT(2));
          }
        }
      }
      // if the gain is not "enough", don't bother!
      if (gain <= min_impurity_decrease) {
        gain = -NumericLimits<DataT>::kMax;
      }
      sp.update({sbins[i], col, gain, nLeft});
    }
    return sp;
  }
};

template <typename DataT, typename IdxT>
DI void regressionMetricGain(DataT* slabel_cdf, IdxT* scount_cdf,
                             DataT label_sum, DataT* sbins,
                             Split<DataT, IdxT>& sp, IdxT col, IdxT len,
                             IdxT nbins, IdxT min_samples_leaf,
                             DataT min_impurity_decrease) {
  auto invlen = DataT(1.0) / len;
  for (IdxT i = threadIdx.x; i < nbins; i += blockDim.x) {
    auto nLeft = scount_cdf[i];
    auto nRight = len - nLeft;
    DataT gain;
    // if there aren't enough samples in this split, don't bother!
    if (nLeft < min_samples_leaf || nRight < min_samples_leaf) {
      gain = -NumericLimits<DataT>::kMax;
    } else {
      DataT parent_obj = -label_sum * label_sum / len;
      DataT left_obj = -(slabel_cdf[i] * slabel_cdf[i]) / nLeft;
      DataT right_label_sum = slabel_cdf[i] - label_sum;
      DataT right_obj = -(right_label_sum * right_label_sum) / nRight;
      gain = parent_obj - (left_obj + right_obj);
      gain *= invlen;
    }
    // if the gain is not "enough", don't bother!
    if (gain <= min_impurity_decrease) {
      gain = -NumericLimits<DataT>::kMax;
    }
    sp.update({sbins[i], col, gain, nLeft});
  }
}

}  // namespace DecisionTree
}  // namespace ML
