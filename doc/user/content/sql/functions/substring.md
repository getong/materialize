---
title: "SUBSTRING function"
description: "Returns substring at specified positions"
menu:
  main:
    parent: 'sql-functions'
---

`SUBSTRING` returns a specified substring of a string.

## Signatures

```mzsql
substring(str, start_pos)
substring(str, start_pos, len)
substring(str FROM start_pos)
substring(str FOR len)
substring(str FROM start_pos FOR len)
```

Parameter | Type | Description
----------|------|------------
_str_ | [`string`](../../types/string) | The base string.
_start&lowbar;pos_ | [`int`](../../types/int) | The starting position for the substring; counting starts at 1.
_len_ | [`int`](../../types/int) | The length of the substring you want to return.

### Return value

`substring` returns a [`string`](../../types/string).

## Examples

```mzsql
SELECT substring('abcdefg', 3) AS substr;
```
```nofmt
 substr
--------
 cdefg
```

 <hr/>

```mzsql
SELECT substring('abcdefg', 3, 3) AS substr;
```
```nofmt
 substr
--------
 cde
```
