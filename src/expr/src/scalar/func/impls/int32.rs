// Copyright Materialize, Inc. and contributors. All rights reserved.
//
// Use of this software is governed by the Business Source License
// included in the LICENSE file.
//
// As of the Change Date specified in that file, in accordance with
// the Business Source License, use of this software will be governed
// by the Apache License, Version 2.0.

use std::fmt;

use mz_lowertest::MzReflect;
use mz_ore::cast::ReinterpretCast;
use mz_repr::adt::numeric::{self, Numeric, NumericMaxScale};
use mz_repr::adt::system::{Oid, PgLegacyChar};
use mz_repr::{ColumnType, ScalarType, strconv};
use serde::{Deserialize, Serialize};

use crate::EvalError;
use crate::scalar::func::EagerUnaryFunc;

sqlfunc!(
    #[sqlname = "-"]
    #[preserves_uniqueness = true]
    #[inverse = to_unary!(NegInt32)]
    #[is_monotone = true]
    fn neg_int32(a: i32) -> Result<i32, EvalError> {
        a.checked_neg()
            .ok_or_else(|| EvalError::Int32OutOfRange(a.to_string().into()))
    }
);

sqlfunc!(
    #[sqlname = "~"]
    #[preserves_uniqueness = true]
    #[inverse = to_unary!(BitNotInt32)]
    fn bit_not_int32(a: i32) -> i32 {
        !a
    }
);

sqlfunc!(
    #[sqlname = "abs"]
    fn abs_int32(a: i32) -> Result<i32, EvalError> {
        a.checked_abs()
            .ok_or_else(|| EvalError::Int32OutOfRange(a.to_string().into()))
    }
);

sqlfunc!(
    #[sqlname = "integer_to_boolean"]
    #[preserves_uniqueness = false]
    #[inverse = to_unary!(super::CastBoolToInt32)]
    fn cast_int32_to_bool(a: i32) -> bool {
        a != 0
    }
);

sqlfunc!(
    #[sqlname = "integer_to_real"]
    #[preserves_uniqueness = false]
    #[inverse = to_unary!(super::CastFloat32ToInt32)]
    #[is_monotone = true]
    fn cast_int32_to_float32(a: i32) -> f32 {
        // TODO(benesch): remove potentially dangerous usage of `as`.
        #[allow(clippy::as_conversions)]
        {
            a as f32
        }
    }
);

sqlfunc!(
    #[sqlname = "integer_to_double"]
    #[preserves_uniqueness = true]
    #[inverse = to_unary!(super::CastFloat64ToInt32)]
    #[is_monotone = true]
    fn cast_int32_to_float64(a: i32) -> f64 {
        f64::from(a)
    }
);

sqlfunc!(
    #[sqlname = "integer_to_smallint"]
    #[preserves_uniqueness = true]
    #[inverse = to_unary!(super::CastInt16ToInt32)]
    #[is_monotone = true]
    fn cast_int32_to_int16(a: i32) -> Result<i16, EvalError> {
        i16::try_from(a).or_else(|_| Err(EvalError::Int16OutOfRange(a.to_string().into())))
    }
);

sqlfunc!(
    #[sqlname = "integer_to_bigint"]
    #[preserves_uniqueness = true]
    #[inverse = to_unary!(super::CastInt64ToInt32)]
    #[is_monotone = true]
    fn cast_int32_to_int64(a: i32) -> i64 {
        i64::from(a)
    }
);

sqlfunc!(
    #[sqlname = "integer_to_text"]
    #[preserves_uniqueness = true]
    #[inverse = to_unary!(super::CastStringToInt32)]
    fn cast_int32_to_string(a: i32) -> String {
        let mut buf = String::new();
        strconv::format_int32(&mut buf, a);
        buf
    }
);

sqlfunc!(
    #[sqlname = "integer_to_uint2"]
    #[preserves_uniqueness = true]
    #[inverse = to_unary!(super::CastUint16ToInt32)]
    #[is_monotone = true]
    fn cast_int32_to_uint16(a: i32) -> Result<u16, EvalError> {
        u16::try_from(a).or_else(|_| Err(EvalError::UInt16OutOfRange(a.to_string().into())))
    }
);

sqlfunc!(
    #[sqlname = "integer_to_uint4"]
    #[preserves_uniqueness = true]
    #[inverse = to_unary!(super::CastUint32ToInt32)]
    #[is_monotone = true]
    fn cast_int32_to_uint32(a: i32) -> Result<u32, EvalError> {
        u32::try_from(a).or_else(|_| Err(EvalError::UInt32OutOfRange(a.to_string().into())))
    }
);

sqlfunc!(
    #[sqlname = "integer_to_uint8"]
    #[preserves_uniqueness = true]
    #[inverse = to_unary!(super::CastUint64ToInt32)]
    #[is_monotone = true]
    fn cast_int32_to_uint64(a: i32) -> Result<u64, EvalError> {
        u64::try_from(a).or_else(|_| Err(EvalError::UInt64OutOfRange(a.to_string().into())))
    }
);

#[derive(Ord, PartialOrd, Clone, Debug, Eq, PartialEq, Serialize, Deserialize, Hash, MzReflect)]
pub struct CastInt32ToNumeric(pub Option<NumericMaxScale>);

impl<'a> EagerUnaryFunc<'a> for CastInt32ToNumeric {
    type Input = i32;
    type Output = Result<Numeric, EvalError>;

    fn call(&self, a: i32) -> Result<Numeric, EvalError> {
        let mut a = Numeric::from(a);
        if let Some(scale) = self.0 {
            if numeric::rescale(&mut a, scale.into_u8()).is_err() {
                return Err(EvalError::NumericFieldOverflow);
            }
        }
        // Besides `rescale`, cast is infallible.
        Ok(a)
    }

    fn output_type(&self, input: ColumnType) -> ColumnType {
        ScalarType::Numeric { max_scale: self.0 }.nullable(input.nullable)
    }

    fn could_error(&self) -> bool {
        self.0.is_some()
    }

    fn inverse(&self) -> Option<crate::UnaryFunc> {
        to_unary!(super::CastNumericToInt32)
    }

    fn is_monotone(&self) -> bool {
        true
    }
}

impl fmt::Display for CastInt32ToNumeric {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("integer_to_numeric")
    }
}

sqlfunc!(
    #[sqlname = "integer_to_oid"]
    #[preserves_uniqueness = true]
    #[inverse = to_unary!(super::CastOidToInt32)]
    fn cast_int32_to_oid(a: i32) -> Oid {
        // For historical reasons in PostgreSQL, the bytes of the `i32` are
        // reinterpreted as a `u32` without bounds checks, so negative `i32`s
        // become very large positive OIDs.
        //
        // Do not use this as a model for behavior in other contexts. OIDs
        // should not in general be thought of as freely convertible from
        // `i32`s.
        Oid(u32::reinterpret_cast(a))
    }
);

sqlfunc!(
    #[sqlname = "integer_to_\"char\""]
    #[preserves_uniqueness = true]
    #[inverse = to_unary!(super::CastPgLegacyCharToInt32)]
    fn cast_int32_to_pg_legacy_char(a: i32) -> Result<PgLegacyChar, EvalError> {
        // Per PostgreSQL, casts to `PgLegacyChar` are performed as if
        // `PgLegacyChar` is signed.
        // See: https://github.com/postgres/postgres/blob/791b1b71da35d9d4264f72a87e4078b85a2fcfb4/src/backend/utils/adt/char.c#L91-L96
        let a = i8::try_from(a).map_err(|_| EvalError::CharOutOfRange)?;
        Ok(PgLegacyChar(u8::reinterpret_cast(a)))
    }
);

sqlfunc!(
    fn chr(a: i32) -> Result<String, EvalError> {
        // This error matches the behavior of Postgres 13/14 (and potentially earlier versions)
        // Postgres 15 will have a different error message for negative values
        let codepoint = u32::try_from(a).map_err(|_| EvalError::CharacterTooLargeForEncoding(a))?;
        if codepoint == 0 {
            Err(EvalError::NullCharacterNotPermitted)
        } else if 0xd800 <= codepoint && codepoint < 0xe000 {
            // Postgres returns a different error message for inputs in this range
            Err(EvalError::CharacterNotValidForEncoding(a))
        } else {
            char::from_u32(codepoint)
                .map(|u| u.to_string())
                .ok_or(EvalError::CharacterTooLargeForEncoding(a))
        }
    }
);
