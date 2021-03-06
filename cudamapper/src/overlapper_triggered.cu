/*
 * Copyright (c) 2019, NVIDIA CORPORATION.  All rights reserved.
 *
 * NVIDIA CORPORATION and its licensors retain all intellectual property
 * and proprietary rights in and to this software, related documentation
 * and any modifications thereto.  Any use, reproduction, disclosure or
 * distribution of this software and related documentation without an express
 * license agreement from NVIDIA CORPORATION is strictly prohibited.
 */

#include <cub/cub.cuh>
#include <thrust/device_vector.h>
#include <thrust/sort.h>
#include <fstream>
#include <cstdlib>

#include <claragenomics/utils/cudautils.hpp>
#include "cudamapper_utils.hpp"
#include "overlapper_triggered.hpp"

namespace claragenomics
{
namespace cudamapper
{

__host__ __device__ bool operator==(const Anchor& lhs,
                                    const Anchor& rhs)
{
    auto score_threshold = 1;

    // Very simple scoring function to quantify quality of overlaps.
    // TODO change to a more sophisticated scoring method
    auto score = 1;

    if ((rhs.query_position_in_read_ - lhs.query_position_in_read_) < 350 and abs(int(rhs.target_position_in_read_) - int(lhs.target_position_in_read_)) < 350)
        score = 2;
    return ((lhs.query_read_id_ == rhs.query_read_id_) &&
            (lhs.target_read_id_ == rhs.target_read_id_) &&
            score > score_threshold);
}

struct cuOverlapKey
{
    const Anchor* anchor;
};

struct cuOverlapKey_transform
{
    const Anchor* d_anchors;
    const int32_t* d_chain_start;

    cuOverlapKey_transform(const Anchor* anchors, const int32_t* chain_start)
        : d_anchors(anchors)
        , d_chain_start(chain_start)
    {
    }

    __host__ __device__ __forceinline__ cuOverlapKey
    operator()(const int32_t& idx) const
    {
        auto anchor_idx = d_chain_start[idx];

        cuOverlapKey key;
        key.anchor = &d_anchors[anchor_idx];
        return key;
    }
};

__host__ __device__ bool operator==(const cuOverlapKey& key0,
                                    const cuOverlapKey& key1)
{
    const Anchor* a = key0.anchor;
    const Anchor* b = key1.anchor;
    return (a->target_read_id_ == b->target_read_id_) &&
           (a->query_read_id_ == b->query_read_id_);
}

struct cuOverlapArgs
{
    int32_t overlap_end;
    int32_t num_residues;
    int32_t overlap_start;
};

struct cuOverlapArgs_transform
{
    const int32_t* d_chain_start;
    const int32_t* d_chain_length;

    cuOverlapArgs_transform(const int32_t* chain_start, const int32_t* chain_length)
        : d_chain_start(chain_start)
        , d_chain_length(chain_length)
    {
    }

    __host__ __device__ __forceinline__ cuOverlapArgs
    operator()(const int32_t& idx) const
    {
        cuOverlapArgs overlap;
        auto overlap_start    = d_chain_start[idx];
        auto overlap_length   = d_chain_length[idx];
        overlap.overlap_end   = overlap_start + overlap_length;
        overlap.num_residues  = overlap_length;
        overlap.overlap_start = overlap_start;
        return overlap;
    }
};

struct FuseOverlapOp
{
    __host__ __device__ cuOverlapArgs operator()(const cuOverlapArgs& a,
                                                 const cuOverlapArgs& b) const
    {
        cuOverlapArgs fused_overlap;
        fused_overlap.num_residues = a.num_residues + b.num_residues;
        fused_overlap.overlap_end =
            a.overlap_end > b.overlap_end ? a.overlap_end : b.overlap_end;
        fused_overlap.overlap_start =
            a.overlap_start < b.overlap_start ? a.overlap_start : b.overlap_start;
        return fused_overlap;
    }
};

struct CreateOverlap
{
    const Anchor* d_anchors;

    __host__ __device__ __forceinline__ CreateOverlap(const Anchor* anchors_ptr)
        : d_anchors(anchors_ptr)
    {
    }

    __host__ __device__ __forceinline__ Overlap
    operator()(cuOverlapArgs overlap)
    {
        Anchor overlap_start_anchor = d_anchors[overlap.overlap_start];
        Anchor overlap_end_anchor   = d_anchors[overlap.overlap_end - 1];

        Overlap new_overlap;

        new_overlap.query_read_id_  = overlap_end_anchor.query_read_id_;
        new_overlap.target_read_id_ = overlap_end_anchor.target_read_id_;
        new_overlap.num_residues_   = overlap.num_residues;
        new_overlap.target_end_position_in_read_ =
            overlap_end_anchor.target_position_in_read_;
        new_overlap.target_start_position_in_read_ =
            overlap_start_anchor.target_position_in_read_;
        new_overlap.query_end_position_in_read_ =
            overlap_end_anchor.query_position_in_read_;
        new_overlap.query_start_position_in_read_ =
            overlap_start_anchor.query_position_in_read_;
        new_overlap.overlap_complete = true;
        new_overlap.cigar_           = 0;

        // If the target start position is greater than the target end position
        // We can safely assume that the query and target are template and
        // complement reads. TODO: Incorporate sketchelement direction value when
        // this is implemented
        if (new_overlap.target_start_position_in_read_ >
            new_overlap.target_end_position_in_read_)
        {
            new_overlap.relative_strand = RelativeStrand::Reverse;
            auto tmp                    = new_overlap.target_end_position_in_read_;
            new_overlap.target_end_position_in_read_ =
                new_overlap.target_start_position_in_read_;
            new_overlap.target_start_position_in_read_ = tmp;
        }
        else
        {
            new_overlap.relative_strand = RelativeStrand::Forward;
        }
        return new_overlap;
    };
};

OverlapperTriggered::OverlapperTriggered(std::shared_ptr<DeviceAllocator> allocator)
    : _allocator(allocator)
{
    CGA_CU_CHECK_ERR(cudaStreamCreate(&stream));
}
OverlapperTriggered::~OverlapperTriggered()
{
    CGA_CU_CHECK_ERR(cudaStreamSynchronize(stream));
    CGA_CU_CHECK_ERR(cudaStreamDestroy(stream));
}

void OverlapperTriggered::get_overlaps(std::vector<Overlap>& fused_overlaps,
                                       device_buffer<Anchor>& d_anchors,
                                       const Index& index_query,
                                       const Index& index_target)
{
    CGA_NVTX_RANGE(profiler, "OverlapperTriggered::get_overlaps");
    const auto tail_length_for_chain = 3;
    auto n_anchors                   = d_anchors.size();

    // comparison operator - lambda used to compare Anchors in sort
    auto comp = [] __host__ __device__(const Anchor& i, const Anchor& j) -> bool {
        return (i.query_read_id_ < j.query_read_id_) ||
               ((i.query_read_id_ == j.query_read_id_) &&
                (i.target_read_id_ < j.target_read_id_)) ||
               ((i.query_read_id_ == j.query_read_id_) &&
                (i.target_read_id_ == j.target_read_id_) &&
                (i.query_position_in_read_ < j.query_position_in_read_)) ||
               ((i.query_read_id_ == j.query_read_id_) &&
                (i.target_read_id_ == j.target_read_id_) &&
                (i.query_position_in_read_ == j.query_position_in_read_) &&
                (i.target_position_in_read_ < j.target_position_in_read_));
    };

    auto thrust_exec_policy = thrust::cuda::par.on(stream);

    // sort on device
    // TODO : currently thrust::sort requires O(2N) auxiliary storage, implement the same functionality using O(N) auxiliary storage
    thrust::sort(thrust_exec_policy, d_anchors.begin(), d_anchors.end(), comp);

    // temporary workspace buffer on device
    device_buffer<char> d_temp_buf(_allocator, stream);

    // Do run length encode to compute the chains
    // note - identifies the start and end anchor of the chain without moving the anchors
    // >>>>>>>>>

    // d_start_anchor[i] contains the starting anchor of chain i
    device_buffer<Anchor> d_start_anchor(n_anchors, _allocator, stream);

    // d_chain_length[i] contains the length of chain i
    device_buffer<int32_t> d_chain_length(n_anchors, _allocator, stream);

    // total number of chains found
    device_buffer<int32_t> d_nchains(1, _allocator, stream);

    void* d_temp_storage      = nullptr;
    size_t temp_storage_bytes = 0;
    // calculate storage requirement for run length encoding
    cub::DeviceRunLengthEncode::Encode(
        d_temp_storage, temp_storage_bytes, d_anchors.data(), d_start_anchor.data(),
        d_chain_length.data(), d_nchains.data(), n_anchors, stream);

    // allocate temporary storage
    d_temp_buf.resize(temp_storage_bytes, stream);
    d_temp_storage = d_temp_buf.data();

    // run encoding
    cub::DeviceRunLengthEncode::Encode(
        d_temp_storage, temp_storage_bytes, d_anchors.data(), d_start_anchor.data(),
        d_chain_length.data(), d_nchains.data(), n_anchors, stream);

    // <<<<<<<<<<

    // memcpy D2H
    auto n_chains = cudautils::get_value_from_device(d_nchains.data(), stream);

    // use prefix sum to calculate the starting index position of all the chains
    // >>>>>>>>>>>>

    // for a chain i, d_chain_start[i] contains the index of starting anchor from d_anchors array
    device_buffer<int32_t> d_chain_start(n_chains, _allocator, stream);

    d_temp_storage     = nullptr;
    temp_storage_bytes = 0;
    cub::DeviceScan::ExclusiveSum(d_temp_storage, temp_storage_bytes,
                                  d_chain_length.data(), d_chain_start.data(),
                                  n_chains, stream);

    // allocate temporary storage
    d_temp_buf.resize(temp_storage_bytes, stream);
    d_temp_storage = d_temp_buf.data();

    cub::DeviceScan::ExclusiveSum(d_temp_storage, temp_storage_bytes,
                                  d_chain_length.data(), d_chain_start.data(),
                                  n_chains, stream);

    // <<<<<<<<<<<<

    // calculate overlaps where overlap is a chain with length > tail_length_for_chain
    // >>>>>>>>>>>>

    // d_overlaps[j] contains index to d_chain_length/d_chain_start where
    // d_chain_length[d_overlaps[j]] and d_chain_start[d_overlaps[j]] corresponds
    // to length and index to starting anchor of the chain-d_overlaps[j] (also referred as overlap j)
    device_buffer<int32_t> d_overlaps(n_chains, _allocator, stream);
    auto indices_end =
        thrust::copy_if(thrust_exec_policy, thrust::make_counting_iterator<int32_t>(0),
                        thrust::make_counting_iterator<int32_t>(n_chains),
                        d_chain_length.data(), d_overlaps.data(),
                        [=] __host__ __device__(const int32_t& len) -> bool {
                            return (len >= tail_length_for_chain);
                        });

    auto n_overlaps = indices_end - d_overlaps.data();

    // <<<<<<<<<<<<<

    // >>>>>>>>>>>>
    // fuse overlaps using reduce by key operations

    // key is a minimal data structure that is required to compare the overlaps
    cuOverlapKey_transform key_op(d_anchors.data(),
                                  d_chain_start.data());
    cub::TransformInputIterator<cuOverlapKey, cuOverlapKey_transform, int32_t*>
        d_keys_in(d_overlaps.data(),
                  key_op);

    // value is a minimal data structure that represents a overlap
    cuOverlapArgs_transform value_op(d_chain_start.data(),
                                     d_chain_length.data());

    cub::TransformInputIterator<cuOverlapArgs, cuOverlapArgs_transform, int32_t*>
        d_values_in(d_overlaps.data(),
                    value_op);

    device_buffer<cuOverlapKey> d_fusedoverlap_keys(n_overlaps, _allocator, stream);
    device_buffer<cuOverlapArgs> d_fusedoverlaps_args(n_overlaps, _allocator, stream);
    device_buffer<int32_t> d_nfused_overlaps(1, _allocator, stream);

    FuseOverlapOp reduction_op;

    d_temp_storage     = nullptr;
    temp_storage_bytes = 0;
    cub::DeviceReduce::ReduceByKey(d_temp_storage, temp_storage_bytes, d_keys_in,
                                   d_fusedoverlap_keys.data(), d_values_in,
                                   d_fusedoverlaps_args.data(), d_nfused_overlaps.data(),
                                   reduction_op, n_overlaps, stream);

    // allocate temporary storage
    d_temp_buf.resize(temp_storage_bytes, stream);
    d_temp_storage = d_temp_buf.data();

    cub::DeviceReduce::ReduceByKey(d_temp_storage, temp_storage_bytes, d_keys_in,
                                   d_fusedoverlap_keys.data(), d_values_in,
                                   d_fusedoverlaps_args.data(), d_nfused_overlaps.data(),
                                   reduction_op, n_overlaps, stream);

    // memcpyD2H
    auto n_fused_overlap = cudautils::get_value_from_device(d_nfused_overlaps.data(), stream);

    // construct overlap from the overlap args
    CreateOverlap fuse_op(d_anchors.data());
    device_buffer<Overlap> d_fused_overlaps(n_fused_overlap, _allocator, stream);
    thrust::transform(thrust_exec_policy, d_fusedoverlaps_args.data(),
                      d_fusedoverlaps_args.data() + n_fused_overlap,
                      d_fused_overlaps.data(), fuse_op);

    // memcpyD2H - move fused overlaps to host
    fused_overlaps.resize(n_fused_overlap);
    cudautils::device_copy_n(d_fused_overlaps.data(), n_fused_overlap, fused_overlaps.data(), stream);
    CGA_CU_CHECK_ERR(cudaStreamSynchronize(stream));

    // <<<<<<<<<<<<
    // parallel update the overlaps to include the corresponding read names [parallel on host]
    thrust::transform(thrust::host,
                      fused_overlaps.data(),
                      fused_overlaps.data() + n_fused_overlap,
                      fused_overlaps.data(), [&](Overlap& new_overlap) {
                          std::string query_read_name  = index_query.read_id_to_read_name(new_overlap.query_read_id_);
                          std::string target_read_name = index_target.read_id_to_read_name(new_overlap.target_read_id_);

                          new_overlap.query_read_name_ = new char[query_read_name.length()];
                          strcpy(new_overlap.query_read_name_, query_read_name.c_str());

                          new_overlap.target_read_name_ = new char[target_read_name.length()];
                          strcpy(new_overlap.target_read_name_, target_read_name.c_str());

                          new_overlap.query_length_  = index_query.read_id_to_read_length(new_overlap.query_read_id_);
                          new_overlap.target_length_ = index_target.read_id_to_read_length(new_overlap.target_read_id_);

                          return new_overlap;
                      });
}
} // namespace cudamapper
} // namespace claragenomics
