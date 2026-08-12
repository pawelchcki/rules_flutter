# Link with the final install RPATH so GNU build IDs do not depend on CMake's
# scratch-directory build RPATH before the install step rewrites it.
set(CMAKE_BUILD_WITH_INSTALL_RPATH ON CACHE BOOL "" FORCE)
