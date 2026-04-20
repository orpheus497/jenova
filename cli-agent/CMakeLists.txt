# ============================================================================
# cli-agent — Pure C + Lua + llama.cpp
# CMake Build Configuration
#
# Architecture:
#   Lua 5.4 (application + agent logic) + C (all services) + llama.cpp (inference)
#   NO Rust dependency. All system services implemented in C11.
# ============================================================================
cmake_minimum_required(VERSION 3.16)
project(cli-agent VERSION 0.2.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# ── Options ──────────────────────────────────────────────────────────────
option(AGENT_USE_LUAJIT   "Use LuaJIT instead of Lua 5.4"  OFF)
option(AGENT_STATIC       "Build static binary"             OFF)
option(AGENT_SANITIZE     "Enable AddressSanitizer"         OFF)
option(AGENT_WITH_LLAMA   "Build with llama.cpp support"    OFF)
option(AGENT_WITH_OPENSSL "Build with OpenSSL crypto"       ON)

# ── Compiler flags ───────────────────────────────────────────────────────
add_compile_options(
    -Wall -Wextra -Wpedantic
    -Wno-unused-parameter
    -D_POSIX_C_SOURCE=200809L
)

if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    add_compile_options(-g -O0 -DDEBUG)
else()
    add_compile_options(-O2 -DNDEBUG)
endif()

if(AGENT_SANITIZE)
    add_compile_options(-fsanitize=address -fno-omit-frame-pointer)
    add_link_options(-fsanitize=address)
endif()

# ── Platform detection ───────────────────────────────────────────────────
if(APPLE)
    add_compile_definitions(PLATFORM_MACOS)
elseif(CMAKE_SYSTEM_NAME STREQUAL "FreeBSD")
    add_compile_definitions(PLATFORM_FREEBSD)
elseif(UNIX)
    add_compile_definitions(PLATFORM_LINUX)
elseif(WIN32)
    add_compile_definitions(PLATFORM_WINDOWS)
endif()

# ── Vendored Lua 5.4 ────────────────────────────────────────────────────
if(NOT AGENT_USE_LUAJIT)
    set(LUA_DIR ${CMAKE_SOURCE_DIR}/vendor/lua-5.4.7/src)

    if(EXISTS ${LUA_DIR}/lua.h)
        file(GLOB LUA_SOURCES ${LUA_DIR}/*.c)
        list(FILTER LUA_SOURCES EXCLUDE REGEX "lua\\.c$")
        list(FILTER LUA_SOURCES EXCLUDE REGEX "luac\\.c$")

        add_library(lua54 STATIC ${LUA_SOURCES})
        target_include_directories(lua54 PUBLIC ${LUA_DIR})

        if(UNIX AND NOT APPLE)
            if(CMAKE_SYSTEM_NAME STREQUAL "FreeBSD")
                target_compile_definitions(lua54 PUBLIC LUA_USE_POSIX)
                target_link_libraries(lua54 PUBLIC m)
            else()
                target_compile_definitions(lua54 PUBLIC LUA_USE_LINUX)
                target_link_libraries(lua54 PUBLIC m dl)
            endif()
        elseif(APPLE)
            target_compile_definitions(lua54 PUBLIC LUA_USE_MACOSX)
            target_link_libraries(lua54 PUBLIC m)
        endif()

        set(LUA_LIBRARY lua54)
        set(LUA_INCLUDE_DIR ${LUA_DIR})
    else()
        find_package(Lua REQUIRED)
        set(LUA_LIBRARY ${LUA_LIBRARIES})
        set(LUA_INCLUDE_DIR ${LUA_INCLUDE_DIR})
    endif()
else()
    find_package(LuaJIT REQUIRED)
    set(LUA_LIBRARY ${LUAJIT_LIBRARIES})
    set(LUA_INCLUDE_DIR ${LUAJIT_INCLUDE_DIR})
endif()

# ── Find libcurl ─────────────────────────────────────────────────────────
find_package(CURL REQUIRED)

# ── Find OpenSSL (optional) ──────────────────────────────────────────────
if(AGENT_WITH_OPENSSL)
    find_package(OpenSSL)
    if(OPENSSL_FOUND)
        add_compile_definitions(HAS_OPENSSL=1)
    endif()
endif()

# ── Source files ─────────────────────────────────────────────────────────
set(AGENT_SOURCES
    src/core/main.c
    src/core/init.c
    src/core/lua_bindings.c
    src/net/net.c
    src/auth/auth.c
    src/crypto/crypto.c
    src/sandbox/sandbox.c
    src/json/json.c
    src/fs/fs.c
    src/process/process.c
    src/mcp/mcp.c
    src/llama/llama.c
    src/agent/agent.c
)

# ── Main executable ─────────────────────────────────────────────────────
add_executable(cli-agent ${AGENT_SOURCES})

target_include_directories(cli-agent PRIVATE
    ${CMAKE_SOURCE_DIR}/include
    ${LUA_INCLUDE_DIR}
    ${CURL_INCLUDE_DIRS}
)

target_link_libraries(cli-agent PRIVATE
    ${LUA_LIBRARY}
    ${CURL_LIBRARIES}
)

if(OPENSSL_FOUND AND AGENT_WITH_OPENSSL)
    target_include_directories(cli-agent PRIVATE ${OPENSSL_INCLUDE_DIR})
    target_link_libraries(cli-agent PRIVATE OpenSSL::Crypto)
endif()

if(UNIX)
    find_package(Threads REQUIRED)
    target_link_libraries(cli-agent PRIVATE Threads::Threads)
endif()

# ── llama.cpp integration ────────────────────────────────────────────────
if(AGENT_WITH_LLAMA)
    target_compile_definitions(cli-agent PRIVATE JENOVA_HAS_LLAMA)
    if(EXISTS "${CMAKE_SOURCE_DIR}/../llama.cpp")
        add_subdirectory(${CMAKE_SOURCE_DIR}/../llama.cpp llama_build)
        target_link_libraries(cli-agent PRIVATE llama common)
        target_include_directories(cli-agent PRIVATE
            ${CMAKE_SOURCE_DIR}/../llama.cpp/include
            ${CMAKE_SOURCE_DIR}/../llama.cpp/common
        )
    endif()
endif()

if(AGENT_STATIC AND NOT APPLE)
    target_link_options(cli-agent PRIVATE -static)
endif()

# ── Install ──────────────────────────────────────────────────────────────
install(TARGETS cli-agent DESTINATION bin)
install(DIRECTORY lua/ DESTINATION share/cli-agent/lua)

# ── Tests ────────────────────────────────────────────────────────────────
enable_testing()

file(GLOB TEST_SOURCES tests/c/*.c)
foreach(test_src ${TEST_SOURCES})
    get_filename_component(test_name ${test_src} NAME_WE)
    add_executable(test_${test_name} ${test_src}
        ${CMAKE_SOURCE_DIR}/src/sandbox/sandbox.c
    )
    target_include_directories(test_${test_name} PRIVATE
        ${CMAKE_SOURCE_DIR}/include
        ${LUA_INCLUDE_DIR}
    )
    target_link_libraries(test_${test_name} PRIVATE ${LUA_LIBRARY} ${CURL_LIBRARIES})
    if(UNIX)
        target_link_libraries(test_${test_name} PRIVATE pthread)
    endif()
    add_test(NAME ${test_name} COMMAND test_${test_name})
endforeach()
