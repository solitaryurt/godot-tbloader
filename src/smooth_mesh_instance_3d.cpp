#include "smooth_mesh_instance_3d.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/mesh.hpp>

void SmoothMeshInstance3D::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_smooth", "smooth"), &SmoothMeshInstance3D::set_smooth);
    ClassDB::bind_method(D_METHOD("get_smooth"), &SmoothMeshInstance3D::get_smooth);
    ClassDB::bind_method(D_METHOD("set_smooth_factor", "factor"), &SmoothMeshInstance3D::set_smooth_factor);
    ClassDB::bind_method(D_METHOD("get_smooth_factor"), &SmoothMeshInstance3D::get_smooth_factor);
    ClassDB::bind_method(D_METHOD("set_original_mesh", "mesh"), &SmoothMeshInstance3D::set_original_mesh);
    ClassDB::bind_method(D_METHOD("get_original_mesh"), &SmoothMeshInstance3D::get_original_mesh);

    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "smooth"), "set_smooth", "get_smooth");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "smooth_factor", PROPERTY_HINT_RANGE, "0,2,0.1"), "set_smooth_factor", "get_smooth_factor");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "original_mesh", PROPERTY_HINT_RESOURCE_TYPE, "Mesh"), "set_original_mesh", "get_original_mesh");
}

void SmoothMeshInstance3D::smooth_mesh_shading() {
    if (original_mesh.is_null()) {
        return;
    }

    // Clamp smoothing factor to reasonable values
    float smoothing_factor = CLAMP(smooth_factor, 0.0f, 2.0f);

    Ref<ArrayMesh> array_mesh = original_mesh;
    if (array_mesh.is_null()) {
        UtilityFunctions::push_error("Only ArrayMesh is supported.");
        return;
    }

    // Create a new ArrayMesh to avoid modifying the original
    Ref<ArrayMesh> new_mesh = memnew(ArrayMesh);

    // Process each surface
    for (int surface_idx = 0; surface_idx < array_mesh->get_surface_count(); surface_idx++) {
        Array arrays = array_mesh->surface_get_arrays(surface_idx);
        if (arrays.size() <= Mesh::ARRAY_NORMAL) {
            continue;
        }

        PackedVector3Array vertices = arrays[Mesh::ARRAY_VERTEX];
        PackedVector3Array normals = arrays[Mesh::ARRAY_NORMAL];

        // Map to track unique vertices and their normals
        std::map<Vector3, std::pair<Vector3, std::vector<int>>> vertex_data;

        // First pass: collect all vertex data
        for (int idx = 0; idx < vertices.size(); idx++) {
            Vector3 vertex = vertices[idx];
            Vector3 normal = normals[idx];

            if (vertex_data.find(vertex) == vertex_data.end()) {
                vertex_data[vertex] = std::make_pair(Vector3(), std::vector<int>());
            }
            vertex_data[vertex].first += normal;
            vertex_data[vertex].second.push_back(idx);
        }

        // Second pass: average normals and apply with smoothing factor
        PackedVector3Array new_normals = normals.duplicate();
        for (auto& pair : vertex_data) {
            // Calculate average normal
            Vector3 avg_normal = pair.second.first.normalized();
            
            // Apply smoothing factor
            Vector3 original_normal = normals[pair.second.second[0]];
            Vector3 final_normal = original_normal.lerp(avg_normal, smoothing_factor).normalized();

            // Apply to all instances of this vertex
            for (int idx : pair.second.second) {
                new_normals.set(idx, final_normal);
            }
        }

        // Update the arrays with new normals
        arrays[Mesh::ARRAY_NORMAL] = new_normals;

        // Add surface to new mesh
        new_mesh->add_surface_from_arrays(array_mesh->surface_get_primitive_type(surface_idx), arrays);

        // Copy surface material
        Ref<Material> mat = array_mesh->surface_get_material(surface_idx);
        if (mat.is_valid()) {
            new_mesh->surface_set_material(surface_idx, mat);
        }
    }

    set_mesh(new_mesh);
}

void SmoothMeshInstance3D::set_smooth(bool p_smooth) {
    smooth = p_smooth;
    if (smooth) {
        smooth_mesh_shading();
    } else {
        set_mesh(original_mesh); // Restore original mesh when smoothing is off
    }
}

bool SmoothMeshInstance3D::get_smooth() const {
    return smooth;
}

void SmoothMeshInstance3D::set_smooth_factor(float p_factor) {
    smooth_factor = p_factor;
    if (smooth) {
        smooth_mesh_shading();
    }
}

float SmoothMeshInstance3D::get_smooth_factor() const {
    return smooth_factor;
}

void SmoothMeshInstance3D::set_original_mesh(const Ref<Mesh> &p_mesh) {
    original_mesh = p_mesh;
    if (!smooth) { // Only set mesh if smoothing is off, otherwise smooth_mesh_shading will handle it
        set_mesh(original_mesh);
    } else {
        smooth_mesh_shading();
    }
}

Ref<Mesh> SmoothMeshInstance3D::get_original_mesh() const {
    return original_mesh;
}

SmoothMeshInstance3D::SmoothMeshInstance3D() {
    smooth = false;
    smooth_factor = 1.0f;
}
