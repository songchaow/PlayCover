// Translated from Metal IR: rps463_ScreenSpaceShadowMap_full_frag_lib332.ll
// Screen-space shadow map shader with cascaded directional shadows, PCF filtering, and SSAO.
// External project shader - not related to our project.
Shader "LYSK/ScreenSpaceShadow/ScreenSpaceShadowMap"
{
    Properties
    {
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" }

        Pass
        {
            Name "ScreenSpaceShadowMap"
            ZTest Always
            ZWrite Off
            Cull Off

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 4.6

            #include "UnityCG.cginc"

            // ==================== Constant Buffers ====================

            // UnityPerCamera (buffer 0, 320 bytes)
            // Built-in: _Time, _SinTime, _CosTime, _TimeParameters, unity_DeltaTime
            // Offset 80: _WorldSpaceRelativeCameraPos (float3)
            // Offset 96: _EyeAdaptionExposure (float)
            // Offset 112: _WorldSpaceCameraPos (float3) - built-in
            // Offset 160: _ProjectionParams (float4) - built-in
            // Offset 176: _ScreenParams (float4) - built-in
            float3 _WorldSpaceRelativeCameraPos;

            // UnityPerPass (buffer 1, 592 bytes)
            // Offset 320 (index 5): InvViewProjMatrix
            float4x4 hlslcc_mtx4x4_InvViewProjMatrix;

            // _LocalLightShadowBuffer (buffer 2, 304 bytes)
            // Offset 208 (index 2, float4 array): CloseUpWorldToShadow (4 float4 rows)
            float4 _CloseUpWorldToShadow_Row0;
            float4 _CloseUpWorldToShadow_Row1;
            float4 _CloseUpWorldToShadow_Row2;
            float4 _CloseUpWorldToShadow_Row3;

            // _DirectionalShadowBuffer (buffer 3, 1376 bytes)
            // Offset 0: hlslcc_mtx4x4_WorldToShadowArray (20 x float4 = 5 cascade matrices)
            float4 _WorldToShadowArray[20];
            // Offset 320: hlslcc_mtx4x4_ShadowToWorldArray (20 x float4) - unused
            // Offset 640: hlslcc_mtx4x4_ShadowInvProjArray (16 x float4) - unused
            // Offset 896 (index 4): _ShadowCameraPosArray (5 x float4)
            float4 _ShadowCameraPosArray[5];
            // Offset 976 (index 4, 16 half): DitherFilters
            half DitherFilters[16];
            // Offset 1008 (index 5): _DirShadowSplitSpheres0
            float4 _DirShadowSplitSpheres0;
            // Offset 1024 (index 6): _DirShadowSplitSpheres1
            float4 _DirShadowSplitSpheres1;
            // Offset 1040 (index 7): _DirShadowSplitSpheres2
            float4 _DirShadowSplitSpheres2;
            // Offset 1056 (index 8): _DirShadowSplitSpheres3
            float4 _DirShadowSplitSpheres3;
            // Offset 1072 (index 9): _DirShadowSplitSphereRadii
            float4 _DirShadowSplitSphereRadii;
            // Offset 1088 (index 10): _ShadowMapClipRanges
            float4 _ShadowMapClipRanges;
            // Offset 1104 (index 11): _ShadowMapSplitDistances
            float4 _ShadowMapSplitDistances;
            // Offset 1184: _ShadowmapSize
            float4 _ShadowmapSize;

            // _ScreenSpaceShadowParams (buffer 4, 32 bytes)
            float2 _ShadowMaskSize;
            float _ZMax;
            float4 _CameraDepthTexture_TexelSize;

            // Textures (using Texture2D for Gather support on shadowmap)
            Texture2D _DirectionalShadowmapTexture;
            SamplerState sampler_DirectionalShadowmapTexture;
            sampler2D _CameraDepthTexture;
            sampler2D _SSAOTexture;

            // ==================== Structures ====================

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float4 pos : SV_POSITION;
                float2 uv : TEXCOORD0;
            };

            // ==================== Vertex Shader ====================

            v2f vert(appdata v)
            {
                v2f o;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;
                return o;
            }

            // ==================== Helper: ImmCB_0 (identity matrix rows) ====================
            // Used as a selector: ImmCB_0[i] selects the i-th component of a float4
            static const float4 ImmCB_0[4] = {
                float4(1, 0, 0, 0),
                float4(0, 1, 0, 0),
                float4(0, 0, 1, 0),
                float4(0, 0, 0, 1)
            };

            // ==================== Helper: Gather ====================
            // Hardware gather: returns the 4 texels that would participate in bilinear filtering.
            // HLSL Texture2D.Gather() returns in the same component order as Metal's gather:
            //   .x = (0,1) bottom-left, .y = (1,1) bottom-right, .z = (1,0) top-right, .w = (0,0) top-left
            // Metal air.gather_texture_2d component order:
            //   .x = (0,0) i.e. top-left, .y = (1,0) top-right, .z = (1,1) bottom-right, .w = (0,1) bottom-left
            // HLSL Gather for component 0 (red channel) returns:
            //   .x = (-0.5,+0.5), .y = (+0.5,+0.5), .z = (+0.5,-0.5), .w = (-0.5,-0.5)
            // Metal gather returns (for component 0):
            //   .x = (+0.5,-0.5), .y = (+0.5,+0.5), .z = (-0.5,+0.5), .w = (-0.5,-0.5)
            // So mapping: Metal.x = HLSL.z, Metal.y = HLSL.y, Metal.z = HLSL.x, Metal.w = HLSL.w
            // => Metal result = HLSL.zyxw
            //
            // Actually let's be precise about gather semantics:
            // HLSL Texture2D.Gather(sampler, uv) with default component 0:
            //   Returns float4 where components are the texels at:
            //   .x = texel at (u - 0.5/w, v + 0.5/h) = bottom-left in UV space (top-left visually if Y-down)
            //   .y = texel at (u + 0.5/w, v + 0.5/h) = bottom-right
            //   .z = texel at (u + 0.5/w, v - 0.5/h) = top-right
            //   .w = texel at (u - 0.5/w, v - 0.5/h) = top-left
            // Metal air.gather_texture_2d returns (for component 0):
            //   Same as HLSL - both follow the D3D11/Metal standard gather pattern.
            // So HLSL Gather result directly matches Metal gather result - no swizzle needed.
            float4 GatherDepth(float2 uv)
            {
                return _DirectionalShadowmapTexture.Gather(sampler_DirectionalShadowmapTexture, uv);
            }

            // ==================== Fragment Shader ====================

            float4 frag(v2f i) : SV_Target
            {
                float2 uv = i.uv;

                // ==== Section 1: Sample depth with offset UV ====
                // IR line 17: depthUV = _CameraDepthTexture_TexelSize.xy * 0.3 + uv
                // 0x3FD3333340000000 as float = 0.3
                float2 depthUV = _CameraDepthTexture_TexelSize.xy * 0.3 + uv;

                // IR line 18-20: sample depth, splat to xxxx
                float rawDepth = tex2D(_CameraDepthTexture, depthUV).r;
                float4 depthVec = rawDepth.xxxx;

                // ==== Section 2: Reconstruct view-space position ====
                // IR lines 26-46: Manual InvViewProjMatrix multiply
                // InvViewProjMatrix is at UnityPerPass buffer offset 320 (member index 5, rows 0-3)
                // IR: result = depth.xxxx * InvVP[2] + InvVP[3]
                //     result += clipY.yyyy * InvVP[1]
                //     result += clipX.xxxx * InvVP[0]
                //
                // clipY computation: _ProjectionParams.x * uv.y
                // clipXY = float2(uv.x, clipY) * 2 + float2(-1, -_ProjectionParams.x)
                float projSign = _ProjectionParams.x;
                float scaledY = projSign * uv.y;
                float clipX = uv.x * 2.0 - 1.0;
                float clipY = scaledY * 2.0 - projSign;

                // Matrix multiply (IR uses column vectors: row0*x + row1*y + row2*z + row3)
                float4 worldH = depthVec * hlslcc_mtx4x4_InvViewProjMatrix[2] + hlslcc_mtx4x4_InvViewProjMatrix[3];
                worldH += clipY.xxxx * hlslcc_mtx4x4_InvViewProjMatrix[1];
                worldH += clipX.xxxx * hlslcc_mtx4x4_InvViewProjMatrix[0];

                // Perspective divide
                float invW = 1.0 / worldH.w;
                float3 viewPos = worldH.xyz * invW; // view-relative world position

                // Absolute world position
                // IR line 52: worldPos = viewPos + _WorldSpaceRelativeCameraPos
                float3 worldPos = viewPos + _WorldSpaceRelativeCameraPos;

                // ==== Section 3: Local light (CloseUp) shadow check ====
                // IR lines 57-85: Transform viewPos by CloseUpWorldToShadow, check if in valid range
                // Uses viewPos.yy, viewPos.xx, viewPos.zz pattern
                float2 localShadowUV;
                localShadowUV  = _CloseUpWorldToShadow_Row1.xy * viewPos.yy;
                localShadowUV  = _CloseUpWorldToShadow_Row0.xy * viewPos.xx + localShadowUV;
                localShadowUV  = _CloseUpWorldToShadow_Row2.xy * viewPos.zz + localShadowUV;
                localShadowUV += _CloseUpWorldToShadow_Row3.xy;

                // IR line 74: checkY = 1.0 - localShadowUV.y
                // IR line 76-77: checkCoord = (localShadowUV.x, checkY) => ndc = checkCoord * 2 - 1
                // IR line 78-82: abs(ndc) < 0.99 (0x3FEFAE1480000000 = double representation of float 0.99)
                float2 checkCoord = float2(localShadowUV.x, 1.0 - localShadowUV.y);
                float2 ndcCheck = checkCoord * 2.0 - 1.0;
                float2 absNdc = abs(ndcCheck);
                // 0x3FEFAE1480000000 as double = float 0x3F7D70A4 = 0.99
                bool inLocal = (absNdc.y < 0.99) && (absNdc.x < 0.99);
                half localMask = inLocal ? (half)1.0 : (half)0.0;
                half dirMask = (half)1.0 - localMask;

                // ==== Section 4: Cascade selection ====
                // IR lines 86-163: Compute distance to cascade spheres and select cascade

                // Distance to split sphere 2 (IR index 7 = _DirShadowSplitSpheres2)
                float3 toSphere2 = worldPos - _DirShadowSplitSpheres2.xyz;
                float distSq2 = dot(toSphere2, toSphere2);

                // Distance to split sphere 0 (IR index 5 = _DirShadowSplitSpheres0)
                float3 toSphere0 = worldPos - _DirShadowSplitSpheres0.xyz;
                float distSq0 = dot(toSphere0, toSphere0);

                // Distance to split sphere 1 (IR index 6 = _DirShadowSplitSpheres1)
                float3 toSphere1 = worldPos - _DirShadowSplitSpheres1.xyz;

                // Distance to camera for max-distance check
                // IR line 102-108: diff to _WorldSpaceCameraPos, dot, fptrunc to half
                float3 toCamera = worldPos - _WorldSpaceCameraPos.xyz;
                float distToCamSq = dot(toCamera, toCamera);
                half distToCamH = (half)distToCamSq;
                float distToCamF = (float)distToCamH;

                // IR line 111-114: _ShadowMapClipRanges.w <= distToCamF ?
                // _ShadowMapClipRanges is at DirectionalShadowBuffer field index 10
                bool beyondMax = _ShadowMapClipRanges.w <= distToCamF;

                float distSq1 = dot(toSphere1, toSphere1);

                // IR line 113-117: distances vector = (distSq0, distSq1, distSq2)
                float3 dists = float3(distSq0, distSq1, distSq2);

                // IR line 118-121: compare dists < _DirShadowSplitSphereRadii.xyz
                float3 radii = _DirShadowSplitSphereRadii.xyz;
                bool3 insideSphere = dists < radii;

                // IR line 122: normalized dist = dists / radii
                float3 normDist = dists / radii;

                // IR line 120-126: clip range check
                // %120 = (distSq0, distSq0, distSq1)
                // compare >= _ShadowMapClipRanges.xyz
                float3 clipTestVals = float3(distSq0, distSq0, distSq1);
                float3 clipRanges = _ShadowMapClipRanges.xyz;
                float3 cascadeValid;
                cascadeValid.x = (clipTestVals.x >= clipRanges.x) ? 1.0 : 0.0;
                cascadeValid.y = (clipTestVals.y >= clipRanges.y) ? 1.0 : 0.0;
                cascadeValid.z = (clipTestVals.z >= clipRanges.z) ? 1.0 : 0.0;

                // IR line 127-148: Build cascade mask and compute weights
                half4 cascadeMaskH;
                cascadeMaskH.x = localMask;
                cascadeMaskH.y = insideSphere.x ? (half)1.0 : (half)0.0;
                cascadeMaskH.z = insideSphere.y ? (half)1.0 : (half)0.0;
                cascadeMaskH.w = insideSphere.z ? (half)1.0 : (half)0.0;

                // IR line 134-139: cascadeDiff = shifted - original
                // %134 = cascadeMaskH.xyz (indices 0,1,2)
                // %135 = cascadeMaskH.yzw (indices 1,2,3)
                // %136 = %135 - %134
                half3 cascadeDiffH = half3(cascadeMaskH.y, cascadeMaskH.z, cascadeMaskH.w)
                                   - half3(cascadeMaskH.x, cascadeMaskH.y, cascadeMaskH.z);

                // IR line 140-142: beyondMax condition affects cascadeWeights.x
                float modifiedWeight = beyondMax ? (float)cascadeMaskH.z : 0.0;
                // IR line 124,139: cascadeWeights = (modifiedWeight, cascadeValid.x, cascadeValid.y, cascadeValid.z)
                float4 cascadeWeights = float4(modifiedWeight, cascadeValid.x, cascadeValid.y, cascadeValid.z);

                // IR line 143-145: max(cascadeDiffH, 0) * dirMask
                half3 posDiff = max(cascadeDiffH, (half3)0.0);
                half3 weightedDiff = posDiff * dirMask;

                // IR line 148: finalMask = (localMask, weightedDiff.x, weightedDiff.y, weightedDiff.z)
                half4 finalMask = half4(cascadeMaskH.x, weightedDiff.x, weightedDiff.y, weightedDiff.z);

                // IR line 149: dot(finalMask, half4(1, 4, 3, 2))
                // 0xH3C00=1, 0xH4400=4, 0xH4200=3, 0xH4000=2
                half cascadeIdxH = dot(finalMask, half4(1, 4, 3, 2));

                // IR line 150-151: blend factor = dot(normDist, float3(weightedDiff))
                float3 weightedDiffF = (float3)weightedDiff;
                float blendFactor = dot(normDist, weightedDiffF);
                half blendH = (half)blendFactor;
                // fma(blendH, 4, -3) clamped [0,1]
                half smoothBlend = saturate(blendH * (half)4.0 + (half)(-3.0));

                // IR line 155-160: (4 - cascadeIdxH), clamp [0, 3] only for ImmCB_0 lookup
                half remainingRaw = (half)4.0 - cascadeIdxH;  // %152: raw value, used later for addition
                half remainingClamped = max(remainingRaw, (half)0.0);
                remainingClamped = min(remainingClamped, (half)3.0);  // %154: clamped only for lookup
                uint cascadeSelect = (uint)(float)remainingClamped;

                // IR line 161-163: dot(cascadeWeights, ImmCB_0[cascadeSelect])
                float4 selector = ImmCB_0[cascadeSelect];
                float selectedW = dot(cascadeWeights, selector);
                half selectedWH = (half)selectedW;

                // ==== Section 5: Dither-based cascade refinement ====
                // IR lines 164-197: Compute dither filter index and refine cascade

                // IR line 167-168: ditherCoord = _ShadowMaskSize * uv, convert to int
                float2 ditherCoord = _ShadowMaskSize * uv;
                int2 ditherInt = (int2)ditherCoord;

                // IR line 169-186: compute signed modulo 4 of dither coordinates
                int2 signBits = ditherInt & (int2)(0x80000000);
                int2 negated = -ditherInt;
                int2 absVal = max(ditherInt, negated);
                int2 mod4 = absVal & 3;
                int2 negMod = -mod4;
                int2 signedResult;
                signedResult.x = (signBits.x == 0) ? mod4.x : negMod.x;
                signedResult.y = (signBits.y == 0) ? mod4.y : negMod.y;
                int2 clampedResult = max(signedResult, (int2)0);

                // IR line 188-193: ditherIndex = clampedResult.y * 4 + clampedResult.x
                int ditherIndex = clampedResult.y * 4 + clampedResult.x;
                half ditherVal = DitherFilters[ditherIndex];

                // IR line 194-195: if smoothBlend >= ditherVal, use selectedWH, else 0
                bool useDither = smoothBlend >= ditherVal;
                half cascadeOffset = useDither ? selectedWH : (half)0.0;

                // IR line 196-200: final cascade index (uses remainingRaw, NOT clamped)
                // IR: %193 = %192 + %152 (adds raw remaining before final clamp)
                half finalCascIdx = cascadeOffset + remainingRaw;
                finalCascIdx = max(finalCascIdx, (half)0.0);
                finalCascIdx = min(finalCascIdx, (half)3.0);
                uint cascadeIdx = (uint)(float)finalCascIdx;

                // ==== Section 6: Shadow space transform ====
                // IR lines 201-227: Transform viewPos to shadow space using selected cascade matrix
                uint matBase = cascadeIdx * 4;

                // row1 = _WorldToShadowArray[matBase + 1].xyz * viewPos.yyy
                float3 shadowPos = _WorldToShadowArray[matBase + 1].xyz * viewPos.yyy;
                // row0 = _WorldToShadowArray[matBase].xyz * viewPos.xxx + shadowPos
                shadowPos = _WorldToShadowArray[matBase].xyz * viewPos.xxx + shadowPos;
                // row2 = _WorldToShadowArray[matBase + 2].xyz * viewPos.zzz + shadowPos
                shadowPos = _WorldToShadowArray[matBase + 2].xyz * viewPos.zzz + shadowPos;
                // row3 = _WorldToShadowArray[matBase + 3].xyz + shadowPos (translation)
                shadowPos = _WorldToShadowArray[matBase + 3].xyz + shadowPos;

                // ==== Section 7: PCF Shadow Sampling ====
                // IR lines 228-339: 5x5 PCF using texture gather operations
                
                float2 shadowUV2D = shadowPos.xy;
                float shadowZ = max(shadowPos.z, 0.0);

                // _ShadowmapSize: xy = texel size (1/mapSize), zw = map size
                float2 texelSz = _ShadowmapSize.xy;
                float2 mapSize = _ShadowmapSize.zw;

                // IR line 229-233: scaled UV = shadowUV * mapSize.zw - 0.5
                // Wait - IR uses _ShadowmapSize at index 18 which is _ShadowmapSize
                // %228 = _ShadowmapSize.zw (from shufflevector <i32 2, i32 3>)
                // %229 = shadowUV * _ShadowmapSize.zw + (-0.5, -0.5)
                float2 scaledUV = shadowUV2D * _ShadowmapSize.zw - 0.5;

                // IR line 235-236: fract and floor
                float2 fractPart = frac(scaledUV);
                float2 floorPart = floor(scaledUV);
                float2 oneMinusFrac = 1.0 - fractPart;

                // IR line 238-239: texelSize * 0.5
                // %235 = _ShadowmapSize.xy (shufflevector <i32 0, i32 1>)
                // %236 = texelSz * 0.5
                float2 halfTexel = texelSz * 0.5;

                // IR line 240: baseUV = floorPart * texelSz + halfTexel
                float2 baseUV = floorPart * texelSz + halfTexel;

                // IR line 241-243: Compute 4 sample UVs with pattern:
                // The IR creates a float4 of texelSize.xyxy then uses fma with offsets:
                // uv_set1 = texelSz.xyxy * (0,-2, 2,-2) + baseUV.xyxy
                float4 texelSzXYXY = float4(texelSz.x, texelSz.y, texelSz.x, texelSz.y);
                float4 baseUVXYXY = float4(baseUV.x, baseUV.y, baseUV.x, baseUV.y);

                // IR line 243: offsets (0,-2, 2,-2)
                float4 uvSet1 = texelSzXYXY * float4(0, -2, 2, -2) + baseUVXYXY;
                // uvSet1.xy = baseUV + texel*(0,-2), uvSet1.zw = baseUV + texel*(2,-2)

                // IR line 256: offsets for another sample: texelSz * (-2) + baseUV
                float2 uvLeft = texelSz * (-2.0) + baseUV;

                // IR line 282: offsets (-2, 0, 2, 0)
                float4 uvSet2 = texelSzXYXY * float4(-2, 0, 2, 0) + baseUVXYXY;

                // IR line 306: offsets (-2, 2, 0, 2)
                float4 uvSet3 = texelSzXYXY * float4(-2, 2, 0, 2) + baseUVXYXY;

                // IR line 307: texelSz * 2 + baseUV
                float2 uvRight = texelSz * 2.0 + baseUV;

                // ---- Gather samples ----
                // Gather 1 (IR line 245): uvSet1.zw (= baseUV + texel*(2,-2))
                float4 gather1 = GatherDepth(uvSet1.zw);
                // Gather 2 (IR line 248): uvSet1.xy (= baseUV + texel*(0,-2))
                float4 gather2 = GatherDepth(uvSet1.xy);
                // Gather 3 (IR line 257): uvLeft (= baseUV + texel*(-2,-2)... actually -2+baseUV)
                float4 gather3 = GatherDepth(uvLeft);
                // Gather 4 (IR line 278): baseUV (center)
                float4 gather4 = GatherDepth(baseUV);
                // Gather 5 (IR line 284): uvSet2.xy (= baseUV + texel*(-2, 0))
                float4 gather5 = GatherDepth(uvSet2.xy);
                // Gather 6 (IR line 287): uvSet2.zw (= baseUV + texel*(2, 0))
                float4 gather6 = GatherDepth(uvSet2.zw);
                // Gather 7 (IR line 308): uvRight (= baseUV + texel*(2, 2))
                float4 gather7 = GatherDepth(uvRight);
                // Gather 8 (IR line 313): uvSet3.xy (= baseUV + texel*(-2, 2))
                float4 gather8 = GatherDepth(uvSet3.xy);
                // Gather 9 (IR line 316): uvSet3.zw (= baseUV + texel*(0, 2))
                float4 gather9 = GatherDepth(uvSet3.zw);

                // ---- Depth comparison: shadowZ >= gathered_depth ? 1 : 0 ----
                float4 shadowZVec = shadowZ.xxxx;
                float4 cmp1 = (shadowZVec >= gather1) ? 1.0 : 0.0; // c1 = from gather1 (uvSet1.zw)
                float4 cmp2 = (shadowZVec >= gather2) ? 1.0 : 0.0; // c2 = from gather2 (uvSet1.xy)
                float4 cmp3 = (shadowZVec >= gather3) ? 1.0 : 0.0; // c3 = from gather3 (uvLeft)
                float4 cmp4 = (shadowZVec >= gather4) ? 1.0 : 0.0; // c4 = from gather4 (baseUV)
                float4 cmp5 = (shadowZVec >= gather5) ? 1.0 : 0.0; // c5 = from gather5 (uvSet2.xy)
                float4 cmp6 = (shadowZVec >= gather6) ? 1.0 : 0.0; // c6 = from gather6 (uvSet2.zw)
                float4 cmp7 = (shadowZVec >= gather7) ? 1.0 : 0.0; // c7 = from gather7 (uvRight)
                float4 cmp8 = (shadowZVec >= gather8) ? 1.0 : 0.0; // c8 = from gather8 (uvSet3.xy)
                float4 cmp9 = (shadowZVec >= gather9) ? 1.0 : 0.0; // c9 = from gather9 (uvSet3.zw)

                // ---- PCF Weight Accumulation ----
                // Following the IR's exact accumulation pattern:
                
                // --- Block 1 (IR lines 258-277): Row using cmp3(uvLeft), cmp2(center-bottom), cmp1(right-bottom) ---
                // IR: %261 = fma(cmp3.wx, oneMinusFrac.xx, cmp3.zy)
                float2 acc1 = cmp3.wx * oneMinusFrac.xx + cmp3.zy;
                // %265 = cmp2.wx + acc1
                acc1 = cmp2.wx + acc1;
                // %266 = acc1 + cmp1.wx
                acc1 = acc1 + cmp1.wx;
                // %267 = acc1 + cmp1.zy  ... wait, IR has cmp2.zy and cmp1
                // Let me re-read the IR more carefully:
                // %258 = cmp3.wx (shuffle <i32 3, i32 0>)
                // %260 = cmp3.zy (shuffle <i32 2, i32 1>)
                // %261 = fma(cmp3.wx, oneMinusFrac.xx, cmp3.zy) = cmp3.wx * oneMinusFrac.xx + cmp3.zy
                // %262 = cmp2.wx (shuffle %250 <i32 3, i32 0>)
                // %263 = cmp2.zy (shuffle %250 <i32 2, i32 1>)
                // %264 = cmp1.wx (shuffle %252 <i32 3, i32 0>)
                // %265 = cmp2.wx + acc1
                // %266 = %265 + cmp1.wx  ... wait:
                // IR line 268: %265 = fadd fast <2 x float> %264, %261  => cmp1.wx + acc1(which is cmp3 result)
                // IR line 269: %266 = fadd fast <2 x float> %265, %262  => + cmp2.wx
                // IR line 270: %267 = fadd fast <2 x float> %266, %263  => + cmp2.zy
                // So the accumulation is: (cmp3.wx * oneMinusFrac.xx + cmp3.zy) + cmp1.wx + cmp2.wx + cmp2.zy
                // Then: %268 = cmp1.zy (shuffle %252 <i32 2, i32 1>)
                // %270 = fma(cmp1.zy, frac.xx, %267) = cmp1.zy * frac.xx + %267
                // %274 = result.x => %277 = fma(result[0], oneMinusFrac.y, result[1])

                // Let me redo this faithfully:
                // cmp3 = gather3 result (uvLeft = baseUV - 2*texel)
                // cmp2 = gather2 result (uvSet1.xy = baseUV + texel*(0,-2))  
                // cmp1 = gather1 result (uvSet1.zw = baseUV + texel*(2,-2))

                // Block1: bottom row
                float2 b1 = cmp3.wx * oneMinusFrac.xx + cmp3.zy;  // IR %261
                b1 = cmp1.wx + b1;                                  // IR %265 (note: IR says %264 + %261)
                b1 = b1 + cmp2.wx;                                  // IR %266
                b1 = b1 + cmp2.zy;                                  // IR %267
                b1 = cmp1.zy * fractPart.xx + b1;                   // IR %270

                float pcf1 = b1.x * oneMinusFrac.y + b1.y;         // IR %274: fma(b1[0], 1-frac.y, b1[1])

                // --- Block 2 (IR lines 290-305): Middle row using cmp5(left), cmp4(center), cmp6(right) ---
                // cmp5 = gather5 (uvSet2.xy = baseUV + texel*(-2,0))
                // cmp4 = gather4 (baseUV)
                // cmp6 = gather6 (uvSet2.zw = baseUV + texel*(2,0))

                float2 b2 = cmp5.wx * oneMinusFrac.xx + cmp5.zy;   // IR %292
                b2 = cmp4.wx + b2;                                   // IR %294 (actually %293 + %292)
                b2 = b2 + cmp4.zy;                                   // IR %296 (+%295)
                b2 = b2 + cmp6.wx;                                   // IR %298 (+%297)
                b2 = cmp6.zy * fractPart.xx + b2;                    // IR %300

                float pcf2_a = b2.y; // IR %301
                float pcf2_b = b2.x; // IR %302

                // --- Block 3 (IR lines 318-336): Top row using cmp8(left), cmp7/cmp9(right/center) ---
                // cmp8 = gather8 (uvSet3.xy = baseUV + texel*(-2,2))
                // cmp9 = gather9 (uvSet3.zw = baseUV + texel*(0,2))
                // cmp7 = gather7 (uvRight = baseUV + texel*(2,2))
                
                // IR: %317 = cmp8 (from gather8, IR line 313-320)
                // %321 = cmp9 (from gather9, IR line 316-324)
                // %308 = cmp7 (from gather7, IR line 308-311)
                // Actually let me re-read:
                // IR line 309-311: gather7 is at uvRight -> cmp7 = %308
                // IR line 313-319: gather8 is at uvSet3.xy -> cmp8_result stored as %317
                // IR line 316-324: gather9 is at uvSet3.zw -> cmp9_result stored as %321

                float2 b3 = cmp8.wx * oneMinusFrac.xx + cmp8.zy;   // IR %320: fma(%318,%259,%319)
                b3 = cmp7.wx + b3;                                   // IR %325: %324 + %320
                b3 = b3 + cmp9.wx;                                   // IR %326: + %322
                b3 = b3 + cmp9.zy;                                   // IR %327: + %323
                b3 = cmp7.zy * fractPart.xx + b3;                    // IR %329: fma(%328,%269,%327)

                float pcf3 = b3.y * fractPart.y + b3.x;             // IR %333: fma(%330,%331,%332)

                // --- Combine ---
                // IR line 337-340: sum = pcf2_b + pcf1 + pcf2_a + pcf3
                float shadowSum = pcf2_b + pcf1 + pcf2_a + pcf3;

                // IR line 340: shadow = shadowSum * 0.04 (0x3FA47AE140000000 = 1/25)
                float shadow = shadowSum * 0.04;
                // IR line 341: shadow squared
                float shadowSq = shadow * shadow;

                // ==== Section 8: Sample SSAO ====
                // IR line 343-346: sample _SSAOTexture at uv, extract .r as half then to float
                half ssaoVal = tex2D(_SSAOTexture, uv).r;
                float ssaoF = (float)ssaoVal;

                // ==== Section 9: Final Output ====
                // IR line 345-349: output = float4(shadowSq, 1, 1, ssaoF)
                return float4(shadowSq, 1.0, 1.0, ssaoF);
            }
            ENDCG
        }
    }

    Fallback Off
}
