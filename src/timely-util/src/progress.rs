// Copyright Materialize, Inc. and contributors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License in the LICENSE file at the
// root of this repository, or online at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Utilities for working with Timely progress tracking.

use proptest::prelude::{Arbitrary, any};
use proptest::strategy::Strategy;
use timely::PartialOrder;
use timely::progress::Antichain;

/// An out-of-crate [`Arbitrary`] implementation for [`Antichain`].
pub fn any_antichain<T>() -> impl Strategy<Value = Antichain<T>>
where
    T: Arbitrary + Ord + PartialOrder,
{
    proptest::collection::vec(any::<T>(), 0..11).prop_map(Into::into)
}
