module LibDeflate

using libdeflate_jll

module LibDeflateErrors

@enum LibDeflateError::UInt8 begin
    deflate_bad_payload
    deflate_output_too_short
    deflate_insufficient_space
    gzip_header_too_short
    gzip_bad_magic_bytes
    gzip_not_deflate
    gzip_string_not_null_terminated
    gzip_null_in_string
    gzip_bad_header_crc16
    gzip_bad_crc32
    gzip_extra_too_long
    gzip_bad_extra
    zlib_input_too_short
    zlib_not_deflate
    zlib_wrong_window_size
    zlib_needs_compression_dict
    zlib_bad_header_check
    zlib_bad_adler32
    zlib_insufficient_space
end

@doc """
    LibDeflateError

An enum representing that LibDeflate encountered an error. The numerical value
of the errors are not stable across non-breaking releases, but their names are.
Successful operations will never return a `LibDeflateError`.
"""
LibDeflateError

export LibDeflateError
end # module

using .LibDeflateErrors

const DEFAULT_COMPRESSION_LEVEL = 6

# Must be mutable for the GC to be able to interact with it
"""
    Decompressor()

Create an object which can decompress using the DEFLATE algorithm.
The same decompressor cannot be used by multiple threads at the same time.
To parallelize decompression, create multiple instances of `Decompressor`
and use one for each thread.

See also: [`decompress!`](@ref), [`unsafe_decompress!`](@ref)
"""
mutable struct Decompressor
    actual_nbytes_ret::UInt
    ptr::Ptr{Nothing}
end

Base.unsafe_convert(::Type{Ptr{Nothing}}, x::Decompressor) = x.ptr

function Decompressor()
    decompressor = Decompressor(0,
        ccall(
            (:libdeflate_alloc_decompressor, libdeflate),
            Ptr{Nothing},
            ()
        )
    )
    finalizer(free_decompressor, decompressor)
    return decompressor
end

function free_decompressor(decompressor::Decompressor)
    ccall(
        (:libdeflate_free_decompressor, libdeflate), 
        Nothing,
        (Ptr{Nothing},),
        decompressor
    )
    return nothing
end

"""
    Compressor(compresslevel::Int=6)

Create an object which can compress using the DEFLATE algorithm. `compresslevel`
can be from 1 (fast) to 12 (slow), and defaults to 6. The same compressor cannot
be used by multiple threads at the same time. To parallelize compression, create
multiple instances of `Compressor` and use one for each thread.

See also: [`compress!`](@ref), [`unsafe_compress!`](@ref)
"""
mutable struct Compressor
    level::Int
    ptr::Ptr{Nothing}
end

Base.unsafe_convert(::Type{Ptr{Nothing}}, x::Compressor) = x.ptr

function Compressor(compresslevel::Integer=DEFAULT_COMPRESSION_LEVEL)
    compresslevel in 1:12 || throw(ArgumentError("Compresslevel must be in 1:12"))
    ptr = ccall(
        (:libdeflate_alloc_compressor, libdeflate),
        Ptr{Nothing},
        (UInt,),
        compresslevel
    )
    compressor = Compressor(compresslevel, ptr)
    finalizer(free_compressor, compressor)
    return compressor
end

function free_compressor(compressor::Compressor)
    ccall((:libdeflate_free_compressor, libdeflate), Nothing, (Ptr{Nothing},), compressor)
    return nothing
end

# Compression and decompression functions

# Raw C call - do not export this
function _unsafe_decompress!(
    decompressor::Decompressor,
    out_ptr::Ptr,
    out_len::Integer,
    in_ptr::Ptr,
    inlen::Integer,
    nptr::Ptr
)::Union{LibDeflateError, Nothing}
    status = ccall(
        (:libdeflate_deflate_decompress, libdeflate),
        UInt,
        (Ptr{Nothing}, Ptr{UInt8}, UInt, Ptr{UInt8}, UInt, Ptr{UInt}),
        decompressor, in_ptr, inlen, out_ptr, out_len, nptr
    )
    if status == Cint(1)
        return LibDeflateErrors.deflate_bad_payload
    elseif status == Cint(2)
        return LibDeflateErrors.deflate_output_too_short
    elseif status == Cint(3)
        return LibDeflateErrors.deflate_insufficient_space
    else
        return nothing
    end
end

"""
    unsafe_decompress!(s::IteratorSize, ::Decompressor, out_ptr, n_out, in_ptr, n_in)

Decompress `n_in` bytes from `in_ptr` to `out_ptr` using the DEFLATE algorithm,
returning the number of decompressed bytes.
`s` gives whether you know the decompressed size or not.

If `s` isa `Base.HasLength`, the number of decompressed bytes is given as `n_out`.
This is more efficient, but will fail if the number is not correct.

If `s` isa `Base.SizeUnknown`, pass the number of available space in the output
to `n_out`.

See also: [`decompress!`](@ref)
"""
function unsafe_decompress! end

function unsafe_decompress!(
    ::Base.HasLength,
    decompressor::Decompressor,
    out_ptr::Ptr,
    n_out::Integer,
    in_ptr::Ptr,
    n_in::Integer
)::Union{LibDeflateError, Int}
    y = _unsafe_decompress!(decompressor, out_ptr, n_out, in_ptr, n_in, C_NULL)
    y isa LibDeflateError ? y : Int(n_out)
end

function unsafe_decompress!(
    ::Base.SizeUnknown,
    decompressor::Decompressor,
    out_ptr::Ptr,
    n_out::Integer,
    in_ptr::Ptr,
    n_in::Integer
)::Union{LibDeflateError, Int}
    y = GC.@preserve decompressor begin
        retptr = pointer_from_objref(decompressor)
        _unsafe_decompress!(decompressor, out_ptr, n_out, in_ptr, n_in, retptr)
    end
    y isa LibDeflateError ? y : (decompressor.actual_nbytes_ret % Int)
end

"""
    decompress!(::Decompressor, out_data, in_data, [n_out::Integer]) -> Int

Use the passed `Decompressor` to decompress the byte vector `in_data` into the
first bytes of `out_data` using the DEFLATE algorithm.
If the decompressed size is known beforehand, pass it as `n_out`. This will increase
performance, but will fail if it is wrong.

Return the number of bytes written to `out_data`.
"""
function decompress! end

# Decompress method with length known (preferred)
function decompress!(
    decompressor::Decompressor,
    out_data::Array,
    in_data,
    n_out::Integer
)::Union{LibDeflateError, Int}
    if sizeof(out_data) < n_out
        throw(ArgumentError("n_out must be less than or equal to byte size of out_data"))
    end
    GC.@preserve out_data in_data unsafe_decompress!(
        Base.HasLength(),
        decompressor,
        pointer(out_data),
        n_out,
        pointer(in_data),
        sizeof(in_data)
    )
end

# Decompress method with length unknown (not preferred)
function decompress!(
    decompressor::Decompressor,
    out_data::Array,
    in_data
)::Union{LibDeflateError, Int}
    GC.@preserve out_data in_data unsafe_decompress!(
        Base.SizeUnknown(),
        decompressor,
        pointer(out_data),
        sizeof(out_data),
        pointer(in_data),
        sizeof(in_data)
    )
end

"""
    unsafe_compress(::Compressor, out_ptr, n_out, in_ptr, n_in)

Use the passed `Compressor` to compress `n_in` bytes from the pointer `in_ptr`
to the pointer `n_out`. If the compressed size is larger than the available
space `n_out`, throw an error.

See also: [`compress!`](@ref)
"""
function unsafe_compress!(
    compressor::Compressor,
    out_ptr::Ptr,
    n_out::Integer,
    in_ptr::Ptr,
    n_in::Integer
)::Union{LibDeflateError, Int}
    bytes = ccall(
        (:libdeflate_deflate_compress, libdeflate),
        UInt,
        (Ptr{Nothing}, Ptr{UInt8}, UInt, Ptr{UInt8}, UInt),
        compressor, in_ptr, n_in, out_ptr, n_out
    )
    iszero(bytes) && return LibDeflateErrors.deflate_insufficient_space
    return bytes % Int
end

"""
    compress!(::Compressor, out_data, in_data) -> Int

Use the passed `Compressor` to compress the byte vector `in_data` into the first
bytes of `out_data` using the DEFLATE algorithm.

The output must fit in `out_data`. Return the number of bytes written to `out_data`.
"""
function compress!(
    compressor::Compressor,
    out_data::Array,
    in_data
)::Union{LibDeflateError, Int}
    GC.@preserve out_data in_data unsafe_compress!(
        compressor,
        pointer(out_data),
        sizeof(out_data),
        pointer(in_data),
        sizeof(in_data)
    )
end

"""
    unsafe_crc32(in_ptr, n_in, start) -> UInt32

Calculate the crc32 checksum of the first `n_in` of the pointer `in_ptr`,
with seed `start` (default is 0).
Note that crc32 is a different and slower algorithm than the `crc32c` provided
in the Julia standard library.

See also: [`crc32`](@ref)
"""
function unsafe_crc32(in_ptr::Ptr, n_in::Integer, start::UInt32=UInt32(0))
    return ccall(
        (:libdeflate_crc32, libdeflate),
        UInt32, (UInt32, Ptr{UInt8}, UInt),
        start, in_ptr, n_in
    )
end

"""
    crc32(data, start=UInt32(0)) -> UInt32

Calculate the crc32 checksum of the byte vector `data` and seed `start`.
Note that crc32 is a different and slower algorithm than the `crc32c` provided
in the Julia standard library.

See also: [`unsafe_crc32`](@ref)
"""
function crc32(data, start::UInt32=UInt32(0))
    GC.@preserve data unsafe_crc32(pointer(data), sizeof(data), start)
end

"""
    unsafe_adler32(data, start=UInt32(1)) -> UInt32

Calculate the adler32 checksum of the first `n_in` of the pointer `in_ptr`,
with seed `start` (default is 1).

See also: [`adler32`](@ref)
"""
function unsafe_adler32(in_ptr::Ptr, n_in::Integer, start::UInt32=UInt32(1))
    return ccall(
        (:libdeflate_adler32, libdeflate),
        UInt32, (UInt32, Ptr{UInt8}, UInt),
        start, in_ptr, n_in
    )
end

"""
    adler32(data, start=UInt32(1)) -> UInt32

Calculate the adler32 checksum of the byte vector `data` and seed `start`.

See also: [`unsafe_adler32`](@ref)
"""
function adler32(data, start::UInt32=UInt32(1))
    GC.@preserve data unsafe_crc32(pointer(data), sizeof(data), start)
end

include("gzip.jl")
include("zlib.jl")

export Decompressor,
       Compressor,

       LibDeflateErrors,
       LibDeflateError,

       unsafe_decompress!,
       decompress!,
       unsafe_compress!,
       compress!,

       unsafe_gzip_decompress!,
       gzip_decompress!,
       unsafe_gzip_compress!,
       gzip_compress!,

       unsafe_zlib_decompress!,
       zlib_decompress!,
       unsafe_zlib_compress!,
       zlib_compress!,

       unsafe_crc32,
       crc32,
       unsafe_adler32,
       adler32,

       unsafe_parse_gzip_header,
       is_valid_extra_data

end # module
