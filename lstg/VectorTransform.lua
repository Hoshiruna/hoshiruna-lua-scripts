---@diagnostic disable: missing-return, unused-local, duplicate-set-field

--------------------------------------------------------------------------------
--- VectorTransforms
---
--- 为 lstg.Vector2 和 lstg.Vector3 提供基本的 2D 和 3D 向量变换。角度以度为单位。
--- 每个变换都接受一个可选的枢轴点和一个可选的输出向量，
--- 因此调用者可以避免内存分配，或者使用本文件末尾注入的链式方法就地修改源向量。
---
--- 退化反射法线和旋转轴将被视为无操作变换，并返回原始向量值。
--------------------------------------------------------------------------------
local function requireVectorModule(name)
    local module = package.loaded[name] or package.loaded["lstg." .. name]
    if module then
        return module
    end

    local ok, result = pcall(require, "lstg." .. name)
    if ok then
        return result
    end
    return require(name)
end

local Vector2 = requireVectorModule("Vector2")
local Vector3 = requireVectorModule("Vector3")

--------------------------------------------------------------------------------
--- 模块定义：线性变换核心算法
--------------------------------------------------------------------------------
---@class lstg.LinearTransformation
local LinearTransformation = {}

-- ==================== 2D 线性变换 ====================

--- 2D缩放
---@param origin lstg.Vector2 原始向量
---@param scale lstg.Vector2 缩放比例
---@param pivot lstg.Vector2|nil 缩放中心点
---@param out lstg.Vector2|nil 接收结果的向量
---@return lstg.Vector2
function LinearTransformation.Scale2D(origin, scale, pivot, out)
    local px = pivot and pivot.x or 0.0
    local py = pivot and pivot.y or 0.0
    out = out or Vector2.create()

    -- 缓存原始相对坐标，防止 out 与 origin 是同一个对象时被覆盖
    local tx = origin.x - px
    local ty = origin.y - py

    out.x = tx * scale.x + px
    out.y = ty * scale.y + py
    return out
end

--- 2D旋转
---@param origin lstg.Vector2 原始向量
---@param angle number 角度(度)
---@param pivot lstg.Vector2|nil 旋转中心点
---@param out lstg.Vector2|nil 接收结果的向量
---@return lstg.Vector2
function LinearTransformation.Rotate2D(origin, angle, pivot, out)
    local px = pivot and pivot.x or 0.0
    local py = pivot and pivot.y or 0.0
    out = out or Vector2.create()

    local rad = math.rad(angle)
    local c = math.cos(rad)
    local s = math.sin(rad)

    local tx = origin.x - px
    local ty = origin.y - py

    out.x = tx * c - ty * s + px
    out.y = tx * s + ty * c + py
    return out
end

--- 2D错切
---@param origin lstg.Vector2 原始向量
---@param shear lstg.Vector2 错切因子
---@param pivot lstg.Vector2|nil 错切中心点
---@param out lstg.Vector2|nil 接收结果的向量
---@return lstg.Vector2
function LinearTransformation.Shear2D(origin, shear, pivot, out)
    local px = pivot and pivot.x or 0.0
    local py = pivot and pivot.y or 0.0
    out = out or Vector2.create()

    local tx = origin.x - px
    local ty = origin.y - py

    out.x = tx + shear.y * ty + px
    out.y = shear.x * tx + ty + py
    return out
end

--- 2D反射(关于直线)
---@param origin lstg.Vector2 原始向量
---@param lineNormal lstg.Vector2 直线法向量
---@param linePoint lstg.Vector2|nil 直线上的点
---@param out lstg.Vector2|nil 接收结果的向量
---@return lstg.Vector2
function LinearTransformation.Reflect2D(origin, lineNormal, linePoint, out)
    local px = linePoint and linePoint.x or 0.0
    local py = linePoint and linePoint.y or 0.0
    out = out or Vector2.create()

    -- 归一化法向量
    local nx = lineNormal.x
    local ny = lineNormal.y
    local len = math.sqrt(nx * nx + ny * ny)
    if len == 0 then
        out.x = origin.x
        out.y = origin.y
        return out
    end
    nx = nx / len
    ny = ny / len

    local tx = origin.x - px
    local ty = origin.y - py

    local dot = tx * nx + ty * ny

    out.x = tx - 2 * dot * nx + px
    out.y = ty - 2 * dot * ny + py
    return out
end

-- ==================== 3D 线性变换 ====================

--- 3D缩放
---@param origin lstg.Vector3
---@param scale lstg.Vector3
---@param pivot lstg.Vector3|nil
---@param out lstg.Vector3|nil
---@return lstg.Vector3
function LinearTransformation.Scale3D(origin, scale, pivot, out)
    local px = pivot and pivot.x or 0.0
    local py = pivot and pivot.y or 0.0
    local pz = pivot and pivot.z or 0.0
    out = out or Vector3.create()

    local tx = origin.x - px
    local ty = origin.y - py
    local tz = origin.z - pz

    out.x = tx * scale.x + px
    out.y = ty * scale.y + py
    out.z = tz * scale.z + pz
    return out
end

--- 3D旋转 (罗德里格斯公式)
---@param origin lstg.Vector3
---@param angle number
---@param axis lstg.Vector3
---@param pivot lstg.Vector3|nil
---@param out lstg.Vector3|nil
---@return lstg.Vector3
function LinearTransformation.Rotate3D(origin, angle, axis, pivot, out)
    local px = pivot and pivot.x or 0.0
    local py = pivot and pivot.y or 0.0
    local pz = pivot and pivot.z or 0.0
    out = out or Vector3.create()

    local rad = math.rad(angle)
    local c = math.cos(rad)
    local s = math.sin(rad)
    local one_minus_c = 1.0 - c

    -- 归一化旋转轴
    local kx = axis.x
    local ky = axis.y
    local kz = axis.z
    local len = math.sqrt(kx * kx + ky * ky + kz * kz)
    if len == 0 then
        out.x = origin.x
        out.y = origin.y
        out.z = origin.z
        return out
    end
    kx = kx / len
    ky = ky / len
    kz = kz / len

    local tx = origin.x - px
    local ty = origin.y - py
    local tz = origin.z - pz

    local cross_x = ky * tz - kz * ty
    local cross_y = kz * tx - kx * tz
    local cross_z = kx * ty - ky * tx

    local dot = kx * tx + ky * ty + kz * tz

    out.x = (tx * c) + (cross_x * s) + (kx * dot * one_minus_c) + px
    out.y = (ty * c) + (cross_y * s) + (ky * dot * one_minus_c) + py
    out.z = (tz * c) + (cross_z * s) + (kz * dot * one_minus_c) + pz

    return out
end

--- 3D错切
---@param origin lstg.Vector3
---@param shear lstg.Vector3
---@param pivot lstg.Vector3|nil
---@param out lstg.Vector3|nil
---@return lstg.Vector3
function LinearTransformation.Shear3D(origin, shear, pivot, out)
    local px = pivot and pivot.x or 0.0
    local py = pivot and pivot.y or 0.0
    local pz = pivot and pivot.z or 0.0
    out = out or Vector3.create()

    local tx = origin.x - px
    local ty = origin.y - py
    local tz = origin.z - pz

    out.x = tx + shear.y * ty + shear.z * tz + px
    out.y = shear.x * tx + ty + shear.z * tz + py
    out.z = shear.x * tx + shear.y * ty + tz + pz
    return out
end

--- 3D反射(关于平面)
---@param origin lstg.Vector3
---@param planeNormal lstg.Vector3
---@param planePoint lstg.Vector3|nil
---@param out lstg.Vector3|nil
---@return lstg.Vector3
function LinearTransformation.Reflect3D(origin, planeNormal, planePoint, out)
    local px = planePoint and planePoint.x or 0.0
    local py = planePoint and planePoint.y or 0.0
    local pz = planePoint and planePoint.z or 0.0
    out = out or Vector3.create()

    -- 归一化法向量
    local nx = planeNormal.x
    local ny = planeNormal.y
    local nz = planeNormal.z
    local len = math.sqrt(nx * nx + ny * ny + nz * nz)
    if len == 0 then
        out.x = origin.x
        out.y = origin.y
        out.z = origin.z
        return out
    end
    nx = nx / len
    ny = ny / len
    nz = nz / len

    local tx = origin.x - px
    local ty = origin.y - py
    local tz = origin.z - pz

    local dot = tx * nx + ty * ny + tz * nz

    out.x = tx - 2 * dot * nx + px
    out.y = ty - 2 * dot * ny + py
    out.z = tz - 2 * dot * nz + pz
    return out
end

--------------------------------------------------------------------------------
--- 注入链式调用扩展到 Vector2 和 Vector3 类
--------------------------------------------------------------------------------

-- 给 Vector2 添加原地(In-place)修改的链式方法
function Vector2:scale(scale, pivot)
    return LinearTransformation.Scale2D(self, scale, pivot, self)
end

function Vector2:rotate(angle, pivot)
    return LinearTransformation.Rotate2D(self, angle, pivot, self)
end

function Vector2:shear(shear, pivot)
    return LinearTransformation.Shear2D(self, shear, pivot, self)
end

function Vector2:reflect(lineNormal, linePoint)
    return LinearTransformation.Reflect2D(self, lineNormal, linePoint, self)
end

-- 给 Vector3 添加原地(In-place)修改的链式方法
function Vector3:scale(scale, pivot)
    return LinearTransformation.Scale3D(self, scale, pivot, self)
end

function Vector3:rotate(angle, axis, pivot)
    return LinearTransformation.Rotate3D(self, angle, axis, pivot, self)
end

function Vector3:shear(shear, pivot)
    return LinearTransformation.Shear3D(self, shear, pivot, self)
end

function Vector3:reflect(planeNormal, planePoint)
    return LinearTransformation.Reflect3D(self, planeNormal, planePoint, self)
end

return LinearTransformation
