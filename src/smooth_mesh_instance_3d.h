#pragma once

#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <map>

using namespace godot;

class SmoothMeshInstance3D : public MeshInstance3D {
    GDCLASS(SmoothMeshInstance3D, MeshInstance3D)

private:
    bool smooth = false;
    float smooth_factor = 1.0f;
    Ref<Mesh> original_mesh;

protected:
    static void _bind_methods();
    void smooth_mesh_shading();

public:
    void set_smooth(bool p_smooth);
    bool get_smooth() const;
    void set_smooth_factor(float p_factor);
    float get_smooth_factor() const;
    void set_original_mesh(const Ref<Mesh> &p_mesh);
    Ref<Mesh> get_original_mesh() const;

    SmoothMeshInstance3D();
};
