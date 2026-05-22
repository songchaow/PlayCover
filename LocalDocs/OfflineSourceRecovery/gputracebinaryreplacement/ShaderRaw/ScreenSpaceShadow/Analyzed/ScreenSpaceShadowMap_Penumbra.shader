// Reverse-translation from external Metal IR disassembly:
//   rps462_ScreenSpaceShadowMap_penumbra_frag_lib330.ll
// This shader has NO relation to this project; it's a faithful semantic
// reconstruction of the fragment program described by the Metal IR (xlatMtlMain).
// The IR was originally produced from HLSL via hlslcc and Apple's metalfe; this
// file maps each IR operation back to the equivalent HLSL/ShaderLab construct so
// that, when compiled, the resulting GPU program is semantically identical.
//
// High-level algorithm (penumbra pass for screen-space cascaded shadow map):
//   1. Sample _CameraDepthTexture at uv biased by 0.3 * texel.
//   2. Reconstruct camera-relative world position via _InvViewProjMatrix.
//   3. Project world pos by _LocalLight CloseUp matrix; if it lies inside the
//      [-0.99, 0.99] NDC box, mark `localShadowFlag = 1` (a local light shadow
//      atlas covers this fragment).
//   4. Compute squared distances to four cascade split spheres and resolve which
//      cascade index (0..3) this fragment falls into.
//   5. Apply dithered cascade-boundary blending using DitherFilters[16].
//   6. Project world pos via WorldToShadowArray[cascade*4 .. cascade*4+3] to get
//      shadow-map coordinate; do a 5x5 PCF tent (using 9 hardware Gather calls)
//      on _DirectionalShadowmapTexture, normalize by 25 and square the result.

Shader "Papegame/LYSK/ScreenSpaceShadow/ScreenSpaceShadowMap_Penumbra"
{
    Properties
    {
        _CameraDepthTexture           ("Camera Depth Texture", 2D) = "white" {}
        _DirectionalShadowmapTexture  ("Directional Shadowmap", 2D) = "white" {}
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" }

        Pass
        {
            Name "ScreenSpaceShadowMap_Penumbra"
            ZTest Always
            ZWrite Off
            Cull Off

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 4.6

            // NOTE: We do NOT include UnityCG.cginc or UnityShaderVariables.cginc
            // because they would conflict with the explicit cbuffer declarations
            // below (which mirror the original Metal IR buffer layout exactly).
            #include "HLSLSupport.cginc"

            // Minimal UnityObjectToClipPos equivalent for the vertex shader.
            float4x4 unity_ObjectToWorld;
            float4x4 unity_MatrixVP;
            inline float4 UnityObjectToClipPos(float4 pos)
            {
                return mul(unity_MatrixVP, mul(unity_ObjectToWorld, pos));
            }

            // ============================================================
            // Constant buffers / textures (names taken directly from the IR
            // metadata: !air.struct_type_info / !air.texture / !air.sampler)
            // ============================================================

            // UnityPerCamera (buffer 0, 320 bytes)
            CBUFFER_START(UnityPerCamera)
                float4 _Time;
                float4 _SinTime;
                float4 _CosTime;
                float4 _TimeParameters;
                float4 unity_DeltaTime;
                float3 _WorldSpaceRelativeCameraPos; float _EyeAdaptionExposure;
                float3 _WorldSpaceCameraPos;         float _EyeAdaptionInverseExposure;
                float3 _WorldSpaceCameraDir;
                float4 _ProjectionParams;
                float4 _ScreenParams;
                float4 _ZBufferParams;
                float4 unity_OrthoParams;
                float3 _PrevCameraPos;               float _ReflectNormalBias;
                float4 _PrevTime;
                float4 _SRPTime;
                float4 _PaperUnscaledTime;
                uint   _FrameCount8;
            CBUFFER_END

            // UnityPerPass (buffer 1, 592 bytes)
            CBUFFER_START(UnityPerPass)
                float4x4 hlslcc_mtx4x4_PrevViewProjMatrix;
                float4x4 hlslcc_mtx4x4_ViewProjMatrix;
                float4x4 hlslcc_mtx4x4_NonJitteredViewProjMatrix;
                float4x4 hlslcc_mtx4x4_ViewMatrix;
                float4x4 hlslcc_mtx4x4_ProjMatrix;
                float4x4 hlslcc_mtx4x4_InvViewProjMatrix;
                float4x4 hlslcc_mtx4x4_InvViewMatrix;
                float4x4 hlslcc_mtx4x4_InvProjMatrix;
                float4   _InvProjParam;
                half4    _ScreenSize;
                half4    _HDRSize;
                half4    _FrustumPlanes[6];
            CBUFFER_END

            // _LocalLightShadowBuffer (buffer 2, 304 bytes)
            CBUFFER_START(_LocalLightShadowBuffer)
                float4   hlslcc_mtx4x4_LocalLightWorldToShadow[12]; // 3 mat4
                half4    _LocalShadowStrength;
                float4x4 hlslcc_mtx4x4_CloseUpWorldToShadow;
                float4   _LocalLightShadowmapSize;
                float4   _LocalLightCloseUpShadowSliceTransform;
            CBUFFER_END

            // _DirectionalShadowBuffer (buffer 3, 1376 bytes)
            CBUFFER_START(_DirectionalShadowBuffer)
                float4 hlslcc_mtx4x4_WorldToShadowArray[20];   // 5 mat4
                float4 hlslcc_mtx4x4_ShadowToWorldArray[20];
                float4 hlslcc_mtx4x4_ShadowInvProjArray[16];   // 4 mat4
                float4 _ShadowCameraPosArray[5];
                half   DitherFilters[16];                      // half[16] in original Metal IR
                float4 _DirShadowSplitSpheres0;
                float4 _DirShadowSplitSpheres1;
                float4 _DirShadowSplitSpheres2;
                float4 _DirShadowSplitSpheres3;
                float4 _DirShadowSplitSphereRadii;
                float4 _ShadowMapClipRanges;
                float4 _ShadowMapSplitDistances;
                float  _InvShadowMapSplitDistances[4];
                half4  _ShadowOffset0;
                half4  _ShadowOffset1;
                half4  _ShadowOffset2;
                half4  _ShadowOffset3;
                half4  _ShadowData;
                float4 _ShadowmapSize;
                float4 hlslcc_mtx4x4_AuroraShadowTransform[4];
                float4 _AuroraShadowCameraPos;
                float  BlurSize;
                float  _PenumbraBias;
                float  _AutoBiasScale;
                float4 _BiasRange[5];
            CBUFFER_END

            // _ScreenSpaceShadowParams (buffer 4, 32 bytes)
            CBUFFER_START(_ScreenSpaceShadowParams)
                float2 _ShadowMaskSize;
                float  _ZMax;
                float4 _CameraDepthTexture_TexelSize;
            CBUFFER_END

            // Texture/sampler bindings (texture 0 / sampler 0 -> directional shadowmap;
            // texture 1 / sampler 1 -> camera depth).
            Texture2D    _DirectionalShadowmapTexture;
            SamplerState sampler_DirectionalShadowmapTexture;

            Texture2D    _CameraDepthTexture;
            SamplerState sampler_CameraDepthTexture;

            // ImmCB_0: identity matrix used to one-hot select an element of a float4
            // by integer cascade index.
            static const float4 ImmCB_0[4] = {
                float4(1.0, 0.0, 0.0, 0.0),
                float4(0.0, 1.0, 0.0, 0.0),
                float4(0.0, 0.0, 1.0, 0.0),
                float4(0.0, 0.0, 0.0, 1.0)
            };

            // ============================================================
            // Vertex (the IR only defines the fragment, but Unity needs a vert).
            // The fragment expects TEXCOORD0 to be the screen UV in [0,1].
            // ============================================================
            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv     : TEXCOORD0;
            };

            struct v2f
            {
                float4 pos : SV_POSITION;
                float2 uv  : TEXCOORD0;
            };

            v2f vert(appdata v)
            {
                v2f o;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.uv  = v.uv;
                return o;
            }

            // ============================================================
            // Fragment: faithful translation of xlatMtlMain.
            //
            // Variable names mirror the IR's SSA registers where useful:
            //   relWP / absWP            -> camera-relative / absolute world pos
            //   distSq{0,1,2}            -> squared distance to each split sphere
            //   localShadowFlag          -> %81 (half) inside-CloseUp-NDC bit
            //   weights{Raw,}            -> %134 / %141 cascade transition weights
            //   packedSum                -> %144 cascade encoding sum
            //   ratioClamped             -> %149 cascade-blend ratio (half)
            //   cascadeIdx               -> %154 lookup index into ImmCB_0
            //   selectedH                -> %159 final cascade-pick gate factor
            //   ditherIdx / ditherFilter -> %187 / %190
            //   shadowAtlasSlice         -> %197 final cascade slot 0..3
            //   shadowCoord              -> %224 mul(WTS_slice, float4(relWP,1)).xyz
            //   pcfBaseUV / fracPart     -> %237 / %232 PCF tent center & frac
            //   g_A..g_I                 -> 9 Gather() footprints
            //   total                    -> %336 PCF tent weighted sum
            //   result = (total / 25)^2  -> %338
            // ============================================================
            float frag(v2f input) : SV_Target0
            {
                float2 uv = input.uv;                                // %9

                // ---- Step 1: depth sample at uv + 0.3 * texelSize.xy ------------
                float2 texelXY = _CameraDepthTexture_TexelSize.xy;   // %14
                float2 sampleUV1 = texelXY * 0.3 + uv;               // %15
                float depthSample =
                    _CameraDepthTexture.Sample(sampler_CameraDepthTexture,
                                               sampleUV1).x;        // %17 -> .x

                // ---- Step 2: reconstruct camera-relative world position ---------
                // ndc.x = 2*uv.x - 1
                // ndc.y = _ProjectionParams.x * (2*uv.y - 1)
                float ppX  = _ProjectionParams.x;                    // %27
                float ndcX = 2.0 * uv.x - 1.0;                       // %33.x
                float ndcY = ppX * (2.0 * uv.y) - ppX;               // %33.y

                // hlslcc convention: each row[i] of the matrix is one column of the
                // original matrix, so the multiply is row0*x + row1*y + row2*z + row3*1.
                float4 invVPRow0 = hlslcc_mtx4x4_InvViewProjMatrix[0];
                float4 invVPRow1 = hlslcc_mtx4x4_InvViewProjMatrix[1];
                float4 invVPRow2 = hlslcc_mtx4x4_InvViewProjMatrix[2];
                float4 invVPRow3 = hlslcc_mtx4x4_InvViewProjMatrix[3];

                float4 clipH = depthSample.xxxx * invVPRow2 + invVPRow3;   // %23
                clipH        = ndcY.xxxx        * invVPRow1 + clipH;       // %37
                clipH        = ndcX.xxxx        * invVPRow0 + clipH;       // %41

                float invW   = 1.0 / clipH.w;                              // %43
                float3 relWP = clipH.xyz * invW.xxx;                       // %47
                float3 absWP = clipH.xyz * invW.xxx +
                               _WorldSpaceRelativeCameraPos;               // %50

                // ---- Step 3: CloseUp shadow projection (local light coverage) ---
                float4 cuRow0 = hlslcc_mtx4x4_CloseUpWorldToShadow[0];
                float4 cuRow1 = hlslcc_mtx4x4_CloseUpWorldToShadow[1];
                float4 cuRow2 = hlslcc_mtx4x4_CloseUpWorldToShadow[2];
                float4 cuRow3 = hlslcc_mtx4x4_CloseUpWorldToShadow[3];

                float2 cuv = cuRow1.xy * relWP.yy;                         // %55
                cuv = cuRow0.xy * relWP.xx + cuv;                          // %60
                cuv = cuRow2.xy * relWP.zz + cuv;                          // %65
                cuv = cuRow3.xy + cuv;                                     // %69

                float2 cuvFlip = float2(cuv.x, 1.0 - cuv.y);               // %74
                float2 cuvNDC  = cuvFlip * 2.0 - 1.0;                      // %75
                float2 cuvAbs  = abs(cuvNDC);                              // %76
                bool  insideX  = cuvAbs.x < 0.99;                          // %77.x
                bool  insideY  = cuvAbs.y < 0.99;                          // %77.y
                bool  insideLocal = insideY && insideX;                    // %80
                half  localShadowFlag    = insideLocal ? (half)1.0 : (half)0.0; // %81
                half  invLocalShadowFlag = (half)1.0 - localShadowFlag;        // %83

                // ---- Step 4: cascade resolution ---------------------------------
                float3 sphere0 = _DirShadowSplitSpheres0.xyz;
                float3 sphere1 = _DirShadowSplitSpheres1.xyz;
                float3 sphere2 = _DirShadowSplitSpheres2.xyz;

                float3 d0v = absWP - sphere0;                              // %93
                float3 d1v = absWP - sphere1;                              // %99
                float3 d2v = absWP - sphere2;                              // %87

                float distSq0 = dot(d0v, d0v);                             // %94
                float distSq1 = dot(d1v, d1v);                             // %110
                float distSq2 = dot(d2v, d2v);                             // %88

                // Distance to camera (squared), then round-trip through half precision.
                float3 dCam   = absWP - _WorldSpaceCameraPos;              // %102
                float distCam = dot(dCam, dCam);                           // %103
                float distCamH = (float)((half)distCam);                   // %105

                bool clipWGate = (_ShadowMapClipRanges.w <= distCamH);     // %109

                float3 radiiXYZ = _DirShadowSplitSphereRadii.xyz;
                bool3 insideC = bool3(distSq0 < radiiXYZ.x,
                                      distSq1 < radiiXYZ.y,
                                      distSq2 < radiiXYZ.z);              // %116
                float3 distRatios = float3(distSq0, distSq1, distSq2) / radiiXYZ; // %117

                float3 clipRangesXYZ = _ShadowMapClipRanges.xyz;
                bool3 gteFlags = bool3(distSq0 >= clipRangesXYZ.x,
                                       distSq0 >= clipRangesXYZ.y,
                                       distSq1 >= clipRangesXYZ.z);       // %120
                float3 gteFloats = float3(gteFlags.x ? 1.0 : 0.0,
                                          gteFlags.y ? 1.0 : 0.0,
                                          gteFlags.z ? 1.0 : 0.0);        // %121

                half c0H = insideC.x ? (half)1.0 : (half)0.0;              // %124
                half c1H = insideC.y ? (half)1.0 : (half)0.0;              // %127
                half c2H = insideC.z ? (half)1.0 : (half)0.0;              // %130

                // weightsRaw = (c0-local, c1-c0, c2-c1), then max(0, .) * (1-local)
                half3 weightsRaw = half3(c0H - localShadowFlag,
                                         c1H - c0H,
                                         c2H - c1H);                      // %134
                half3 weights = max(weightsRaw, (half3)0.0);               // %138
                weights = weights * invLocalShadowFlag.xxx;                // %141

                // packedSum = dot(half4(local, w.x, w.y, w.z), half4(1, 4, 3, 2))
                half packedSum = localShadowFlag * (half)1.0
                               + weights.x       * (half)4.0
                               + weights.y       * (half)3.0
                               + weights.z       * (half)2.0;             // %144

                float3 weightsF = float3(weights);                         // %145
                float ratioF = dot(distRatios, weightsF);                  // %146
                half  ratioH = (half)ratioF;                               // %147
                half  ratioMad = ratioH * (half)4.0 - (half)3.0;           // %148
                half  ratioClamped = clamp(ratioMad, (half)0.0, (half)1.0);// %149

                half  cIdxH    = clamp((half)4.0 - packedSum,
                                       (half)0.0, (half)3.0);             // %152
                uint  cascadeIdx = (uint)((float)cIdxH);                   // %154

                float c1F = (float)c1H;                                    // %135
                float gateVal = clipWGate ? c1F : 0.0;                     // %136
                float4 picker = float4(gateVal, gteFloats.x,
                                       gteFloats.y, gteFloats.z);         // %137
                float selectedF = dot(picker, ImmCB_0[cascadeIdx]);        // %158
                half  selectedH = (half)selectedF;                         // %159

                // ---- Step 5: dithered cascade-boundary picking ------------------
                float2 hdrXY  = float2(_HDRSize.xy);                       // %163
                float2 dxy    = hdrXY * uv;                                // %164
                int2   ixy    = int2(dxy);                                 // %165
                int2   absIxy = max(ixy, -ixy);                            // %168 (= abs)
                int2   modIxy = absIxy & 3;                                // %169
                int2   negModIxy = -modIxy;                                // %170

                int dxFolded = (ixy.x >= 0) ? modIxy.x : negModIxy.x;      // %175
                int dyFolded = (ixy.y >= 0) ? modIxy.y : negModIxy.y;      // %181

                int dxClamped = max(dxFolded, 0);                          // %183.x
                int dyClamped = max(dyFolded, 0);                          // %183.y

                int ditherIdx = dyClamped * 4 + dxClamped;                 // %187
                half ditherFilter = DitherFilters[ditherIdx];              // %190

                half gateFactor = (ratioClamped >= ditherFilter)
                                ? selectedH : (half)0.0;                   // %192

                half  sliceTmp  = gateFactor + ((half)4.0 - packedSum);    // %193
                half  sliceCl   = clamp(sliceTmp, (half)0.0, (half)3.0);   // %195
                uint  shadowAtlasSlice = (uint)((float)sliceCl);           // %197
                int   sliceBase = (int)shadowAtlasSlice * 4;               // %198

                // ---- Step 6: project relWP through WorldToShadowArray[slice] ----
                float3 wtsRow0 = hlslcc_mtx4x4_WorldToShadowArray[sliceBase + 0].xyz;
                float3 wtsRow1 = hlslcc_mtx4x4_WorldToShadowArray[sliceBase + 1].xyz;
                float3 wtsRow2 = hlslcc_mtx4x4_WorldToShadowArray[sliceBase + 2].xyz;
                float3 wtsRow3 = hlslcc_mtx4x4_WorldToShadowArray[sliceBase + 3].xyz;

                float3 shadowCoord = wtsRow1 * relWP.yyy;                  // %205
                shadowCoord = wtsRow0 * relWP.xxx + shadowCoord;           // %211
                shadowCoord = wtsRow2 * relWP.zzz + shadowCoord;           // %218
                shadowCoord = wtsRow3 + shadowCoord;                       // %224

                // ---- Step 7: 5x5 PCF tent on _DirectionalShadowmapTexture --------
                float2 sizeZW = _ShadowmapSize.zw;                         // %228
                float2 sizeXY = _ShadowmapSize.xy;                         // %235
                float2 prePcf = shadowCoord.xy * sizeZW - 0.5;             // %229
                float  depthRef = max(shadowCoord.z, 0.0);                 // %231
                float2 fracPart = frac(prePcf);                            // %232
                float2 floorPart= floor(prePcf);                           // %233
                float2 oneMinusFrac = 1.0 - fracPart;                      // %234
                float2 halfTexel = sizeXY * 0.5;                           // %236
                float2 pcfBaseUV = floorPart * sizeXY + halfTexel;         // %237

                #define GATHER_DEPTH(uv2) \
                    _DirectionalShadowmapTexture.Gather( \
                        sampler_DirectionalShadowmapTexture, (uv2))

                // ----- Block 1: gathers around (0,-2),(2,-2),(-2,-2) offsets -----
                float4 off1 = float4(sizeXY, sizeXY) *
                              float4(0.0, -2.0, 2.0, -2.0) +
                              float4(pcfBaseUV, pcfBaseUV);                // %240
                float4 g_A = GATHER_DEPTH(off1.zw);                        // %243
                float4 g_B = GATHER_DEPTH(off1.xy);                        // %246
                float4 cmp_A = (depthRef.xxxx >= g_A) ? float4(1,1,1,1)
                                                       : float4(0,0,0,0); // %250
                float4 cmp_B = (depthRef.xxxx >= g_B) ? float4(1,1,1,1)
                                                       : float4(0,0,0,0); // %252

                float2 off2 = sizeXY * -2.0 + pcfBaseUV;                   // %253
                float4 g_C  = GATHER_DEPTH(off2);                          // %255
                float4 cmp_C = (depthRef.xxxx >= g_C) ? float4(1,1,1,1)
                                                       : float4(0,0,0,0); // %257

                // %267 = cmp_C.wx*(1-fx).xx + cmp_C.zy + cmp_A.wx + cmp_B.wx + cmp_B.zy
                float2 sumABC = cmp_C.wx * oneMinusFrac.xx + cmp_C.zy
                              + cmp_A.wx
                              + cmp_B.wx + cmp_B.zy;                       // %267
                // %270 = cmp_A.zy * frac.x.xx + sumABC
                float2 sumRow1 = cmp_A.zy * fracPart.xx + sumABC;          // %270
                // %274 = sumRow1.x*(1-frac.y) + sumRow1.y
                float pcfRow1 = sumRow1.x * oneMinusFrac.y + sumRow1.y;    // %274

                // ----- Block 2: gathers around (-2,0), (2,0), (0,0) offsets -----
                float4 g_D = GATHER_DEPTH(pcfBaseUV);                      // %276
                float4 cmp_D = (depthRef.xxxx >= g_D) ? float4(1,1,1,1)
                                                       : float4(0,0,0,0); // %278

                float4 off3 = float4(sizeXY, sizeXY) *
                              float4(-2.0, 0.0, 2.0, 0.0) +
                              float4(pcfBaseUV, pcfBaseUV);                // %279
                float4 g_E = GATHER_DEPTH(off3.xy);                        // %282
                float4 g_F = GATHER_DEPTH(off3.zw);                        // %285
                float4 cmp_E = (depthRef.xxxx >= g_E) ? float4(1,1,1,1)
                                                       : float4(0,0,0,0); // %289
                float4 cmp_F = (depthRef.xxxx >= g_F) ? float4(1,1,1,1)
                                                       : float4(0,0,0,0); // %287

                // %298 = cmp_E.wx*(1-fx).xx + cmp_E.zy + cmp_D.wx + cmp_D.zy + cmp_F.wx
                float2 sumRow2pre = cmp_E.wx * oneMinusFrac.xx + cmp_E.zy
                                  + cmp_D.wx + cmp_D.zy
                                  + cmp_F.wx;                              // %298
                float2 sumRow2 = cmp_F.zy * fracPart.xx + sumRow2pre;      // %300
                float pcfRow2x = sumRow2.x;                                // %302
                float pcfRow2y = sumRow2.y;                                // %301

                // ----- Block 3: gathers around (-2,2), (0,2), (2,2) offsets -----
                float4 off4 = float4(sizeXY, sizeXY) *
                              float4(-2.0, 2.0, 0.0, 2.0) +
                              float4(pcfBaseUV, pcfBaseUV);                // %303
                float2 off5 = sizeXY * 2.0 + pcfBaseUV;                    // %304
                float4 g_G = GATHER_DEPTH(off5);                           // %306
                float4 cmp_G = (depthRef.xxxx >= g_G) ? float4(1,1,1,1)
                                                       : float4(0,0,0,0); // %308
                float4 g_H = GATHER_DEPTH(off4.xy);                        // %311
                float4 g_I = GATHER_DEPTH(off4.zw);                        // %314
                // %317 from %316 (>= g_H), %321 from %315 (>= g_I)
                float4 cmp_H = (depthRef.xxxx >= g_H) ? float4(1,1,1,1)
                                                       : float4(0,0,0,0); // %317
                float4 cmp_I = (depthRef.xxxx >= g_I) ? float4(1,1,1,1)
                                                       : float4(0,0,0,0); // %321

                // %327 = cmp_H.wx*(1-fx).xx + cmp_H.zy + cmp_G.wx + cmp_I.wx + cmp_I.zy
                float2 sumRow3pre = cmp_H.wx * oneMinusFrac.xx + cmp_H.zy
                                  + cmp_G.wx
                                  + cmp_I.wx + cmp_I.zy;                   // %327
                float2 sumRow3 = cmp_G.zy * fracPart.xx + sumRow3pre;      // %329
                float pcfRow3x = sumRow3.x;                                // %332
                float pcfRow3y = sumRow3.y;                                // %330
                // %333 = pcfRow3y * frac.y + pcfRow3x
                float pcfRow3 = pcfRow3y * fracPart.y + pcfRow3x;          // %333

                // %334 = pcfRow2x + pcfRow1
                // %335 = %334 + pcfRow2y
                // %336 = %335 + pcfRow3
                float total = pcfRow2x + pcfRow1;                          // %334
                total       = total + pcfRow2y;                            // %335
                total       = total + pcfRow3;                             // %336

                float scaled = total * 0.04;                               // %337  (1/25)
                float result = scaled * scaled;                            // %338

                #undef GATHER_DEPTH

                return result;                                             // %339
            }

            ENDHLSL
        }
    }

    FallBack Off
}
