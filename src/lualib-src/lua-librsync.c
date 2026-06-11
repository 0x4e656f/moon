#include "lua.h"
#include "lauxlib.h"
#include "librsync.h"

#include <stdint.h>
#include <limits.h>
#include <stdlib.h>

#if !defined(SIZE_MAX)
#define SIZE_MAX ((size_t)-1)
#endif

#if !defined(INTMAX_MAX)
#define INTMAX_MAX ((intmax_t)(SIZE_MAX >> 1))
#endif

#if defined(_WIN32)
#define XLRSYNC_EXPORT __declspec(dllexport)
#else
#define XLRSYNC_EXPORT __attribute__((visibility("default")))
#endif

#if !defined(lua_absindex)
#define lua_absindex(L, i) ((i) > 0 || (i) <= LUA_REGISTRYINDEX ? (i) : lua_gettop(L) + (i) + 1)
#endif

#if !defined(lua_isnoneornil)
#define lua_isnoneornil(L, i) (lua_type((L), (i)) <= LUA_TNIL)
#endif

#if LUA_VERSION_NUM < 502
#define luaL_newlib(L, l) (lua_newtable(L), luaL_register(L, NULL, l))
#endif

#define XLRSYNC_GUARD_MT "xlrsync.buffer_guard"
#define XLRSYNC_INITIAL_OUT_CAPACITY ((size_t)65536)
#define XLRSYNC_MAX_INITIAL_OUT_CAPACITY ((size_t)1048576)

typedef struct xlrsync_buffer_guard {
    char *ptr;
} xlrsync_buffer_guard;

typedef struct xlrsync_output {
    xlrsync_buffer_guard *guard;
    char *data;
    size_t capacity;
} xlrsync_output;

typedef struct xlrsync_basis {
    const char *data;
    size_t len;
} xlrsync_basis;

static int xlrsync_buffer_guard_gc(lua_State *L) {
    xlrsync_buffer_guard *guard = (xlrsync_buffer_guard *)lua_touserdata(L, 1);
    if (guard != NULL && guard->ptr != NULL) {
        free(guard->ptr);
        guard->ptr = NULL;
    }
    return 0;
}

static xlrsync_buffer_guard *xlrsync_push_buffer_guard(lua_State *L) {
    xlrsync_buffer_guard *guard = (xlrsync_buffer_guard *)lua_newuserdata(L, sizeof(*guard));
    guard->ptr = NULL;

    if (luaL_newmetatable(L, XLRSYNC_GUARD_MT)) {
        lua_pushcfunction(L, xlrsync_buffer_guard_gc);
        lua_setfield(L, -2, "__gc");
    }
    lua_setmetatable(L, -2);
    return guard;
}

static int xlrsync_output_init(xlrsync_output *out, xlrsync_buffer_guard *guard, size_t hint) {
    size_t capacity = hint;
    if (capacity < XLRSYNC_INITIAL_OUT_CAPACITY) {
        capacity = XLRSYNC_INITIAL_OUT_CAPACITY;
    }
    if (capacity > XLRSYNC_MAX_INITIAL_OUT_CAPACITY) {
        capacity = XLRSYNC_MAX_INITIAL_OUT_CAPACITY;
    }

    out->guard = guard;
    out->data = (char *)malloc(capacity);
    out->capacity = capacity;

    if (out->data == NULL) {
        out->capacity = 0;
        return 0;
    }

    guard->ptr = out->data;
    return 1;
}

static void xlrsync_output_discard(xlrsync_output *out) {
    if (out != NULL && out->guard != NULL && out->guard->ptr != NULL) {
        free(out->guard->ptr);
        out->guard->ptr = NULL;
    }
    if (out != NULL) {
        out->data = NULL;
        out->capacity = 0;
    }
}

static int xlrsync_output_grow(xlrsync_output *out, size_t used) {
    size_t new_capacity = out->capacity;

    if (new_capacity == 0) {
        new_capacity = XLRSYNC_INITIAL_OUT_CAPACITY;
    }

    while (new_capacity <= used) {
        if (new_capacity > SIZE_MAX / 2) {
            return 0;
        }
        new_capacity *= 2;
    }

    {
        char *new_data = (char *)realloc(out->data, new_capacity);
        if (new_data == NULL) {
            return 0;
        }

        out->data = new_data;
        out->capacity = new_capacity;
        out->guard->ptr = new_data;
    }

    return 1;
}

static int xlrsync_push_output_and_release(lua_State *L, int guard_index, xlrsync_output *out, size_t len) {
    char *data = out->data;

    lua_pushlstring(L, data, len);

    free(data);
    out->data = NULL;
    out->capacity = 0;
    out->guard->ptr = NULL;

    lua_remove(L, guard_index);
    return 1;
}

static int xlrsync_error_result(lua_State *L, const char *op, rs_result res) {
    return luaL_error(L, "librsync: %s failed: %s (%d)", op, rs_strerror(res), (int)res);
}

static int xlrsync_error_oom(lua_State *L, const char *where) {
    return luaL_error(L, "librsync: out of memory%s%s", where != NULL ? " in " : "", where != NULL ? where : "");
}

static rs_result xlrsync_run_job(rs_job_t *job, const char *input, size_t input_len,
                                 xlrsync_output *out, size_t *out_len) {
    rs_buffers_t buf;
    rs_result res = RS_BLOCKED;

    buf.next_in = (char *)input;
    buf.avail_in = input_len;
    buf.eof_in = 1;
    buf.next_out = out->data;
    buf.avail_out = out->capacity;
    *out_len = 0;

    while (res == RS_BLOCKED) {
        char *prev_in = buf.next_in;
        char *prev_out = buf.next_out;
        size_t prev_avail_in = buf.avail_in;
        size_t prev_avail_out = buf.avail_out;

        res = rs_job_iter(job, &buf);
        *out_len = (size_t)(buf.next_out - out->data);

        if (res != RS_BLOCKED) {
            break;
        }

        if (buf.avail_out == 0) {
            if (!xlrsync_output_grow(out, *out_len)) {
                return RS_MEM_ERROR;
            }
            buf.next_out = out->data + *out_len;
            buf.avail_out = out->capacity - *out_len;
            continue;
        }

        if (buf.next_in == prev_in &&
            buf.next_out == prev_out &&
            buf.avail_in == prev_avail_in &&
            buf.avail_out == prev_avail_out) {
            return RS_INTERNAL_ERROR;
        }
    }

    return res;
}

static rs_result xlrsync_run_input_only_job(rs_job_t *job, const char *input, size_t input_len) {
    char discard[1];
    rs_buffers_t buf;
    rs_result res = RS_BLOCKED;

    buf.next_in = (char *)input;
    buf.avail_in = input_len;
    buf.eof_in = 1;
    buf.next_out = discard;
    buf.avail_out = sizeof(discard);

    while (res == RS_BLOCKED) {
        char *prev_in = buf.next_in;
        char *prev_out = buf.next_out;
        size_t prev_avail_in = buf.avail_in;
        size_t prev_avail_out = buf.avail_out;

        res = rs_job_iter(job, &buf);

        if (res != RS_BLOCKED) {
            break;
        }

        if (buf.avail_out == 0) {
            buf.next_out = discard;
            buf.avail_out = sizeof(discard);
            continue;
        }

        if (buf.next_in == prev_in &&
            buf.next_out == prev_out &&
            buf.avail_in == prev_avail_in &&
            buf.avail_out == prev_avail_out) {
            return RS_INTERNAL_ERROR;
        }
    }

    return res;
}

static rs_result xlrsync_load_signature(const char *sig, size_t sig_len, rs_signature_t **sumset) {
    rs_job_t *job;
    rs_result res;

    *sumset = NULL;
    job = rs_loadsig_begin(sumset);
    if (job == NULL) {
        return RS_MEM_ERROR;
    }

    res = xlrsync_run_input_only_job(job, sig, sig_len);
    rs_job_free(job);

    if (res != RS_DONE) {
        if (*sumset != NULL) {
            rs_free_sumset(*sumset);
            *sumset = NULL;
        }
        return res;
    }

    res = rs_build_hash_table(*sumset);
    if (res != RS_DONE) {
        rs_free_sumset(*sumset);
        *sumset = NULL;
    }

    return res;
}

static rs_result xlrsync_memory_copy_cb(void *opaque, rs_long_t pos, size_t *len, void **buf) {
    xlrsync_basis *basis = (xlrsync_basis *)opaque;
    size_t upos;
    size_t available;

    if (basis == NULL || len == NULL || buf == NULL || pos < 0) {
        return RS_PARAM_ERROR;
    }

    upos = (size_t)pos;
    if ((rs_long_t)upos != pos || upos >= basis->len) {
        *len = 0;
        return RS_INPUT_ENDED;
    }

    available = basis->len - upos;
    if (*len > available) {
        *len = available;
    }

    *buf = (void *)(basis->data + upos);
    return *len > 0 ? RS_DONE : RS_INPUT_ENDED;
}

static int xlrsync_read_size_arg(lua_State *L, int index, size_t default_value,
                                 int allow_minus_one, size_t *out) {
    lua_Integer value;

    if (lua_isnoneornil(L, index)) {
        *out = default_value;
        return 1;
    }

    value = luaL_checkinteger(L, index);
    if (value < 0) {
        if (allow_minus_one && value == -1) {
            *out = (size_t)-1;
            return 1;
        }
        luaL_argerror(L, index, "expected non-negative integer");
        return 0;
    }

    *out = (size_t)value;
    if ((lua_Integer)*out != value) {
        luaL_argerror(L, index, "integer is too large");
        return 0;
    }

    return 1;
}

static lua_Integer xlrsync_get_table_integer(lua_State *L, int table_index,
                                             const char *name, lua_Integer default_value) {
    lua_Integer value;

    table_index = lua_absindex(L, table_index);
    lua_getfield(L, table_index, name);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return default_value;
    }

    value = luaL_checkinteger(L, -1);
    lua_pop(L, 1);
    return value;
}

static void xlrsync_read_sig_options(lua_State *L, int first_option_index,
                                     size_t *block_len, size_t *strong_len,
                                     rs_magic_number *magic) {
    if (lua_istable(L, first_option_index)) {
        lua_Integer block_value = xlrsync_get_table_integer(L, first_option_index, "block_len", 0);
        lua_Integer strong_value = xlrsync_get_table_integer(L, first_option_index, "strong_len", 0);
        lua_Integer magic_value = xlrsync_get_table_integer(L, first_option_index, "magic", 0);

        if (block_value < 0) {
            luaL_error(L, "librsync: block_len must be non-negative");
        }
        if (strong_value < -1) {
            luaL_error(L, "librsync: strong_len must be non-negative or -1");
        }

        *block_len = (size_t)block_value;
        *strong_len = strong_value == -1 ? (size_t)-1 : (size_t)strong_value;
        *magic = (rs_magic_number)magic_value;
        return;
    }

    xlrsync_read_size_arg(L, first_option_index, 0, 0, block_len);
    xlrsync_read_size_arg(L, first_option_index + 1, 0, 1, strong_len);
    *magic = (rs_magic_number)luaL_optinteger(L, first_option_index + 2, 0);
}

static int l_sig_args(lua_State *L) {
    rs_long_t old_fsize = -1;
    size_t block_len = 0;
    size_t strong_len = 0;
    rs_magic_number magic = (rs_magic_number)0;
    rs_result res;

    if (lua_type(L, 1) == LUA_TSTRING) {
        size_t old_len;
        luaL_checklstring(L, 1, &old_len);
        if (old_len > (size_t)INTMAX_MAX) {
            return luaL_error(L, "librsync: input is too large");
        }
        old_fsize = (rs_long_t)old_len;
        xlrsync_read_sig_options(L, 2, &block_len, &strong_len, &magic);
    } else {
        lua_Integer value = luaL_optinteger(L, 1, -1);
        if (value < -1) {
            return luaL_argerror(L, 1, "expected file size or -1");
        }
        old_fsize = (rs_long_t)value;
        xlrsync_read_sig_options(L, 2, &block_len, &strong_len, &magic);
    }

    res = rs_sig_args(old_fsize, &magic, &block_len, &strong_len);
    if (res != RS_DONE) {
        return xlrsync_error_result(L, "sig_args", res);
    }

    lua_createtable(L, 0, 3);
    lua_pushinteger(L, (lua_Integer)block_len);
    lua_setfield(L, -2, "block_len");
    lua_pushinteger(L, (lua_Integer)strong_len);
    lua_setfield(L, -2, "strong_len");
    lua_pushinteger(L, (lua_Integer)magic);
    lua_setfield(L, -2, "magic");
    return 1;
}

static int l_signature(lua_State *L) {
    size_t old_len;
    const char *old_buf = luaL_checklstring(L, 1, &old_len);
    size_t block_len = 0;
    size_t strong_len = 0;
    rs_magic_number magic = (rs_magic_number)0;
    xlrsync_buffer_guard *guard;
    xlrsync_output out;
    rs_job_t *job;
    rs_result res;
    size_t out_len = 0;
    int guard_index;

    if (old_len > (size_t)INTMAX_MAX) {
        return luaL_error(L, "librsync: input is too large");
    }

    xlrsync_read_sig_options(L, 2, &block_len, &strong_len, &magic);

    res = rs_sig_args((rs_long_t)old_len, &magic, &block_len, &strong_len);
    if (res != RS_DONE) {
        return xlrsync_error_result(L, "signature argument validation", res);
    }

    guard_index = lua_gettop(L) + 1;
    guard = xlrsync_push_buffer_guard(L);

    job = rs_sig_begin(block_len, strong_len, magic);
    if (job == NULL) {
        return xlrsync_error_oom(L, "rs_sig_begin");
    }

    if (!xlrsync_output_init(&out, guard, XLRSYNC_INITIAL_OUT_CAPACITY)) {
        rs_job_free(job);
        return xlrsync_error_oom(L, "signature output allocation");
    }

    res = xlrsync_run_job(job, old_buf, old_len, &out, &out_len);
    rs_job_free(job);

    if (res != RS_DONE) {
        xlrsync_output_discard(&out);
        return xlrsync_error_result(L, "signature", res);
    }

    return xlrsync_push_output_and_release(L, guard_index, &out, out_len);
}

static int l_delta(lua_State *L) {
    size_t sig_len;
    size_t new_len;
    const char *sig_buf = luaL_checklstring(L, 1, &sig_len);
    const char *new_buf = luaL_checklstring(L, 2, &new_len);
    xlrsync_buffer_guard *guard;
    xlrsync_output out;
    rs_signature_t *sumset = NULL;
    rs_job_t *job;
    rs_result res;
    size_t out_len = 0;
    int guard_index;

    guard_index = lua_gettop(L) + 1;
    guard = xlrsync_push_buffer_guard(L);

    res = xlrsync_load_signature(sig_buf, sig_len, &sumset);
    if (res != RS_DONE) {
        return xlrsync_error_result(L, "load signature", res);
    }

    job = rs_delta_begin(sumset);
    if (job == NULL) {
        rs_free_sumset(sumset);
        return xlrsync_error_oom(L, "rs_delta_begin");
    }

    if (!xlrsync_output_init(&out, guard, new_len / 2)) {
        rs_job_free(job);
        rs_free_sumset(sumset);
        return xlrsync_error_oom(L, "delta output allocation");
    }

    res = xlrsync_run_job(job, new_buf, new_len, &out, &out_len);
    rs_job_free(job);
    rs_free_sumset(sumset);

    if (res != RS_DONE) {
        xlrsync_output_discard(&out);
        return xlrsync_error_result(L, "delta", res);
    }

    return xlrsync_push_output_and_release(L, guard_index, &out, out_len);
}

static int l_patch(lua_State *L) {
    size_t basis_len;
    size_t delta_len;
    const char *basis_buf = luaL_checklstring(L, 1, &basis_len);
    const char *delta_buf = luaL_checklstring(L, 2, &delta_len);
    xlrsync_basis basis;
    xlrsync_buffer_guard *guard;
    xlrsync_output out;
    rs_job_t *job;
    rs_result res;
    size_t out_len = 0;
    int guard_index;

    basis.data = basis_buf;
    basis.len = basis_len;

    guard_index = lua_gettop(L) + 1;
    guard = xlrsync_push_buffer_guard(L);

    job = rs_patch_begin(xlrsync_memory_copy_cb, &basis);
    if (job == NULL) {
        return xlrsync_error_oom(L, "rs_patch_begin");
    }

    if (!xlrsync_output_init(&out, guard, basis_len)) {
        rs_job_free(job);
        return xlrsync_error_oom(L, "patch output allocation");
    }

    res = xlrsync_run_job(job, delta_buf, delta_len, &out, &out_len);
    rs_job_free(job);

    if (res != RS_DONE) {
        xlrsync_output_discard(&out);
        return xlrsync_error_result(L, "patch", res);
    }

    return xlrsync_push_output_and_release(L, guard_index, &out, out_len);
}

static int l_version(lua_State *L) {
    lua_pushstring(L, rs_librsync_version);
    return 1;
}

static int l_strerror(lua_State *L) {
    rs_result res = (rs_result)luaL_checkinteger(L, 1);
    lua_pushstring(L, rs_strerror(res));
    return 1;
}

static const luaL_Reg xlrsync_funcs[] = {
    {"signature", l_signature},
    {"compute_signature", l_signature},
    {"delta", l_delta},
    {"compute_delta", l_delta},
    {"patch", l_patch},
    {"apply_patch", l_patch},
    {"sig_args", l_sig_args},
    {"version", l_version},
    {"strerror", l_strerror},
    {NULL, NULL}
};

static void xlrsync_set_int(lua_State *L, const char *name, lua_Integer value) {
    lua_pushinteger(L, value);
    lua_setfield(L, -2, name);
}

XLRSYNC_EXPORT int luaopen_librsync(lua_State *L) {
    luaL_newlib(L, xlrsync_funcs);

    xlrsync_set_int(L, "DONE", RS_DONE);
    xlrsync_set_int(L, "BLOCKED", RS_BLOCKED);
    xlrsync_set_int(L, "IO_ERROR", RS_IO_ERROR);
    xlrsync_set_int(L, "MEM_ERROR", RS_MEM_ERROR);
    xlrsync_set_int(L, "INPUT_ENDED", RS_INPUT_ENDED);
    xlrsync_set_int(L, "BAD_MAGIC", RS_BAD_MAGIC);
    xlrsync_set_int(L, "CORRUPT", RS_CORRUPT);
    xlrsync_set_int(L, "INTERNAL_ERROR", RS_INTERNAL_ERROR);
    xlrsync_set_int(L, "PARAM_ERROR", RS_PARAM_ERROR);

    xlrsync_set_int(L, "DELTA_MAGIC", (lua_Integer)0x72730236);
    xlrsync_set_int(L, "MD4_SIG_MAGIC", (lua_Integer)0x72730136);
    xlrsync_set_int(L, "BLAKE2_SIG_MAGIC", (lua_Integer)0x72730137);
    xlrsync_set_int(L, "RK_MD4_SIG_MAGIC", (lua_Integer)0x72730146);
    xlrsync_set_int(L, "RK_BLAKE2_SIG_MAGIC", (lua_Integer)0x72730147);

    return 1;
}
