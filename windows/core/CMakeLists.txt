# OmniCore.dll: the OmniCast for Windows engine over libobs.
# Built by windows/build.ps1; needs windows/scripts/bootstrap.ps1 to have run.
cmake_minimum_required(VERSION 3.24)
project(OmniCore LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")

set(VENDOR "${CMAKE_CURRENT_SOURCE_DIR}/../vendor")
set(OBS_INCLUDE "${VENDOR}/obs-include")
set(OBS_DLL "${VENDOR}/obs-runtime/bin/64bit/obs.dll")
if(NOT EXISTS "${OBS_DLL}" OR NOT EXISTS "${OBS_INCLUDE}/obs.h")
  message(FATAL_ERROR "libobs isn't set up. Run windows/scripts/bootstrap.ps1 (build.ps1 does this for you).")
endif()

# OBS ships obs.dll without an import library, so make one from its exports.
get_filename_component(MSVC_BIN "${CMAKE_LINKER}" DIRECTORY)
find_program(DUMPBIN dumpbin HINTS "${MSVC_BIN}" REQUIRED)
find_program(LIB_EXE lib HINTS "${MSVC_BIN}" REQUIRED)
set(OBS_DEF "${CMAKE_CURRENT_BINARY_DIR}/obs.def")
set(OBS_LIB "${CMAKE_CURRENT_BINARY_DIR}/obs.lib")
if(NOT EXISTS "${OBS_LIB}" OR "${OBS_DLL}" IS_NEWER_THAN "${OBS_LIB}")
  execute_process(COMMAND "${DUMPBIN}" /nologo /exports "${OBS_DLL}" OUTPUT_VARIABLE exports COMMAND_ERROR_IS_FATAL ANY)
  string(REGEX MATCHALL "\n +[0-9]+ +[0-9A-F]+ +[0-9A-F]+ +[A-Za-z_][A-Za-z0-9_]*" lines "${exports}")
  set(def "LIBRARY obs\nEXPORTS\n")
  foreach(line IN LISTS lines)
    string(REGEX REPLACE ".* ([A-Za-z_][A-Za-z0-9_]*)$" "\\1" name "${line}")
    string(APPEND def "  ${name}\n")
  endforeach()
  file(WRITE "${OBS_DEF}" "${def}")
  execute_process(COMMAND "${LIB_EXE}" /nologo /def:${OBS_DEF} /machine:x64 /out:${OBS_LIB} COMMAND_ERROR_IS_FATAL ANY)
endif()

add_library(OmniCore SHARED
  src/engine.cpp
  src/audio.cpp
  src/preview.cpp
  src/outputs.cpp
  src/scenes.cpp
  src/audio_out.cpp
)
target_include_directories(OmniCore PRIVATE include "${OBS_INCLUDE}")
target_compile_definitions(OmniCore PRIVATE NOMINMAX UNICODE _UNICODE _CRT_SECURE_NO_WARNINGS)
target_compile_options(OmniCore PRIVATE /W3 /utf-8 /permissive- /wd4244 /wd4267)
# obs.dll is loaded on first use, after oc_start points the DLL search at the
# app's obs\bin\64bit folder, so OmniCore.dll itself loads from anywhere.
target_link_libraries(OmniCore PRIVATE "${OBS_LIB}" d3d11 dxgi shell32 ole32 delayimp)
target_link_options(OmniCore PRIVATE /DELAYLOAD:obs.dll)
