/*
* Copyright (c) 2020, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "gtest/gtest.h"

#include <algorithm>
#include <numeric>
#include <random>
#include <vector>

#include <thrust/device_vector.h>
#include <thrust/host_vector.h>

#include <claragenomics/utils/cudasort.cuh>

namespace claragenomics
{

template <typename MoreSignificantKeyT,
          typename LessSignificantKeyT,
          typename ValueT>
void test_function(thrust::device_vector<MoreSignificantKeyT>& more_significant_keys,
                   thrust::device_vector<LessSignificantKeyT>& less_significant_keys,
                   thrust::device_vector<ValueT>& input_values,
                   const MoreSignificantKeyT max_value_of_more_significant_key,
                   const LessSignificantKeyT max_value_of_less_significant_key)
{
    ASSERT_EQ(input_values.size(), more_significant_keys.size());
    ASSERT_EQ(input_values.size(), less_significant_keys.size());

    cudautils::sort_by_two_keys(more_significant_keys,
                                less_significant_keys,
                                input_values,
                                max_value_of_more_significant_key,
                                max_value_of_less_significant_key);

    thrust::host_vector<ValueT> sorted_values_h(input_values);

    ASSERT_EQ(sorted_values_h.size(), input_values.size());
    // sort is done by two keys and not values, but tests cases are intentionally made so the values are sorted as well
    for (std::size_t i = 1; i < input_values.size(); ++i)
    {
        EXPECT_LE(sorted_values_h[i - 1], sorted_values_h[i]) << "index: " << i << std::endl;
    }
}

// repreat this test with differnt combinations of types, more significant key has larger max value than less significant key
template <typename MoreSignificantKeyT,
          typename LessSignificantKeyT,
          typename ValueT>
void short_test_template_larger_more_significant_key()
{
    // more less value
    //   60   1   610
    //   20   4   240
    //   50   5   550
    //   40   2   420
    //   40   5   450
    //   20   1   210
    //   20   2   220
    //   30   8   380
    //   30   7   370
    //   50   1   510
    //   50   3   530
    //   40   5   451
    //   80   4   840
    const std::vector<MoreSignificantKeyT> more_significant_keys_vec = {60, 20, 50, 40, 40, 20, 20, 30, 30, 50, 50, 40, 80};
    const std::vector<LessSignificantKeyT> less_significant_keys_vec = {1, 4, 5, 2, 5, 1, 2, 8, 7, 1, 3, 5, 4};
    const std::vector<ValueT> input_values_vec                       = {610, 240, 550, 420, 450, 210, 220, 380, 370, 510, 530, 451, 840};

    const MoreSignificantKeyT max_value_of_more_significant_key = *std::max_element(std::begin(more_significant_keys_vec),
                                                                                    std::end(more_significant_keys_vec));
    const LessSignificantKeyT max_value_of_less_significant_key = *std::max_element(std::begin(less_significant_keys_vec),
                                                                                    std::end(less_significant_keys_vec));

    thrust::device_vector<MoreSignificantKeyT> more_significant_keys(std::begin(more_significant_keys_vec),
                                                                     std::end(more_significant_keys_vec));
    thrust::device_vector<LessSignificantKeyT> less_significant_keys(std::begin(less_significant_keys_vec),
                                                                     std::end(less_significant_keys_vec));
    thrust::device_vector<ValueT> input_values(std::begin(input_values_vec),
                                               std::end(input_values_vec));

    test_function(more_significant_keys,
                  less_significant_keys,
                  input_values,
                  max_value_of_more_significant_key,
                  max_value_of_less_significant_key);
}

// repreat this test with differnt combinations of types, less significant key has larger max value than more significant key
template <typename MoreSignificantKeyT,
          typename LessSignificantKeyT,
          typename ValueT>
void short_test_template_larger_less_significant_key()
{
    // more less value
    //    6   10   610
    //    2   40   240
    //    5   50   550
    //    4   20   420
    //    4   50   450
    //    2   10   210
    //    2   20   220
    //    3   80   380
    //    3   70   370
    //    5   10   510
    //    5   30   530
    //    4   50   451
    //    8   40   840
    const std::vector<MoreSignificantKeyT> more_significant_keys_vec = {6, 2, 5, 4, 4, 2, 2, 3, 3, 5, 5, 4, 8};
    const std::vector<LessSignificantKeyT> less_significant_keys_vec = {10, 40, 50, 20, 50, 10, 20, 80, 70, 10, 30, 50, 40};
    const std::vector<ValueT> input_values_vec                       = {610, 240, 550, 420, 450, 210, 220, 380, 370, 510, 530, 451, 840};

    const MoreSignificantKeyT max_value_of_more_significant_key = *std::max_element(std::begin(more_significant_keys_vec),
                                                                                    std::end(more_significant_keys_vec));
    const LessSignificantKeyT max_value_of_less_significant_key = *std::max_element(std::begin(less_significant_keys_vec),
                                                                                    std::end(less_significant_keys_vec));

    thrust::device_vector<MoreSignificantKeyT> more_significant_keys(std::begin(more_significant_keys_vec),
                                                                     std::end(more_significant_keys_vec));
    thrust::device_vector<LessSignificantKeyT> less_significant_keys(std::begin(less_significant_keys_vec),
                                                                     std::end(less_significant_keys_vec));
    thrust::device_vector<ValueT> input_values(std::begin(input_values_vec),
                                               std::end(input_values_vec));

    test_function(more_significant_keys,
                  less_significant_keys,
                  input_values,
                  max_value_of_more_significant_key,
                  max_value_of_less_significant_key);
}

TEST(TestUtilsCudasort, short_32_32_32_test)
{
    short_test_template_larger_more_significant_key<std::uint32_t, std::uint32_t, std::uint32_t>();
    short_test_template_larger_less_significant_key<std::uint32_t, std::uint32_t, std::uint32_t>();
}

TEST(TestUtilsCudasort, short_32_32_64_test)
{
    short_test_template_larger_more_significant_key<std::uint32_t, std::uint32_t, std::uint64_t>();
    short_test_template_larger_less_significant_key<std::uint32_t, std::uint32_t, std::uint64_t>();
}

TEST(TestUtilsCudasort, short_32_64_32_test)
{
    short_test_template_larger_more_significant_key<std::uint32_t, std::uint64_t, std::uint32_t>();
    short_test_template_larger_less_significant_key<std::uint32_t, std::uint64_t, std::uint32_t>();
}

TEST(TestUtilsCudasort, short_32_64_64_test)
{
    short_test_template_larger_more_significant_key<std::uint32_t, std::uint64_t, std::uint64_t>();
    short_test_template_larger_less_significant_key<std::uint32_t, std::uint64_t, std::uint64_t>();
}

TEST(TestUtilsCudasort, short_64_32_32_test)
{
    short_test_template_larger_more_significant_key<std::uint64_t, std::uint32_t, std::uint32_t>();
    short_test_template_larger_less_significant_key<std::uint64_t, std::uint32_t, std::uint32_t>();
}

TEST(TestUtilsCudasort, short_64_32_64_test)
{
    short_test_template_larger_more_significant_key<std::uint64_t, std::uint32_t, std::uint64_t>();
    short_test_template_larger_less_significant_key<std::uint64_t, std::uint32_t, std::uint64_t>();
}

TEST(TestUtilsCudasort, short_64_64_32_test)
{
    short_test_template_larger_more_significant_key<std::uint64_t, std::uint64_t, std::uint32_t>();
    short_test_template_larger_less_significant_key<std::uint64_t, std::uint64_t, std::uint32_t>();
}

TEST(TestUtilsCudasort, short_64_64_64_test)
{
    short_test_template_larger_more_significant_key<std::uint64_t, std::uint64_t, std::uint64_t>();
    short_test_template_larger_less_significant_key<std::uint64_t, std::uint64_t, std::uint64_t>();
}

TEST(TestUtilsCudasort, long_deterministic_shuffle_test)
{
    std::int64_t number_of_elements = 10'000'000;

    std::mt19937 g(10);

    // fill the arrays with values 0..number_of_elements and shuffle them
    thrust::host_vector<std::uint32_t> more_significant_keys_h(number_of_elements);
    std::iota(std::begin(more_significant_keys_h), std::end(more_significant_keys_h), 0);
    std::shuffle(std::begin(more_significant_keys_h), std::end(more_significant_keys_h), g);
    thrust::device_vector<std::uint32_t> more_significant_keys_d(more_significant_keys_h);

    thrust::host_vector<std::uint32_t> less_significant_keys_h(number_of_elements);
    std::iota(std::begin(less_significant_keys_h), std::end(less_significant_keys_h), 0);
    std::shuffle(std::begin(less_significant_keys_h), std::end(less_significant_keys_h), g);
    thrust::device_vector<std::uint32_t> less_significant_keys_d(less_significant_keys_h);

    thrust::host_vector<std::uint64_t> input_values_h(number_of_elements);
    std::transform(std::begin(more_significant_keys_h),
                   std::end(more_significant_keys_h),
                   std::begin(less_significant_keys_h),
                   std::begin(input_values_h),
                   [number_of_elements](const std::uint32_t more_significant_key, const std::uint32_t less_significant_key) {
                       return number_of_elements * more_significant_key + less_significant_key;
                   });
    thrust::device_vector<std::uint64_t> input_values_d(input_values_h);

    const std::uint32_t max_value_of_more_significant_key = number_of_elements - 1;
    const std::uint32_t max_value_of_less_significant_key = number_of_elements - 1;

    test_function(more_significant_keys_d,
                  less_significant_keys_d,
                  input_values_d,
                  max_value_of_more_significant_key,
                  max_value_of_less_significant_key);
}

} //namespace claragenomics
