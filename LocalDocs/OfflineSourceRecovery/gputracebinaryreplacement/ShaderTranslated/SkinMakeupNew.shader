Shader "Papegame/SkinMakeupNew"
{
    Properties
    {
        // === 基础贴图/颜色 ===
        _MainTex ("Base Skin Texture (RGB=color, A=eye sparkle mask)", 2D) = "white" {}
        _Color ("Base Color Tint", Color) = (1,1,1,1)
        _SpecularTex ("Specular Tex (R=roughness, B=specular, A=mask)", 2D) = "white" {}
        _NormalTex ("Normal Map (RG=normalA, BA=normalB)", 2D) = "bump" {}
        _EyelidTex ("Eyelid Normal (RG=normal, A=blend weight)", 2D) = "bump" {}

        // === 化妆层贴图 ===
        _EyebrowTex ("Eyebrow Texture", 2D) = "black" {}
        _EyeshadowTex ("Eyeshadow Texture", 2D) = "black" {}
        _EyelinerTex ("Eyeliner Texture", 2D) = "black" {}
        _BlusherTex ("Blusher Texture", 2D) = "black" {}
        _LipTex ("Lip Texture", 2D) = "black" {}
        _DecorateTex ("Decorate Texture 1", 2D) = "black" {}
        _Decorate2Tex ("Decorate Texture 2", 2D) = "black" {}
        _MorphPartTex ("MorphPart Texture", 2D) = "black" {}

        // === 屏幕空间贴图 ===
        _SSSSkinTexture ("SSS Skin LUT (screen space)", 2D) = "white" {}
        _ScreenShadowTexture ("Screen Shadow Texture", 2D) = "white" {}
        _LightIndexMap ("Light Index Map", 2D) = "black" {}

        // === 基础材质参数 ===
        _MainTex_ST ("MainTex ST", Vector) = (1,1,0,0)
        _FresnelColor ("Fresnel Color", Color) = (1,1,1,1)
        _OverlayColor ("Overlay Color", Color) = (1,1,1,1)
        _SparkleUV ("Sparkle UV", Vector) = (1,1,0,0)
        _SSSSkinTexture_TexelSize ("SSS Texel Size", Vector) = (0,0,0,0)
        _Cutoff ("Alpha Cutoff", Range(0,1)) = 0.5
        _ShadowIntensity ("Shadow Intensity", Range(0,1)) = 0.5
        _AOIntensity ("AO Intensity", Range(0,1)) = 1
        _NonMetalSpecular ("Non Metal Specular", Range(0,1)) = 0.04
        _FresnelIntensity ("Fresnel Intensity", Range(0,2)) = 1
        _Fresnelpower ("Fresnel Power", Range(0,10)) = 5
        _LerpValue ("Lerp Value", Range(0,1)) = 0
        _LeftEyeInfo ("Left Eye Info", Range(0,1)) = 0
        _RightEyeInfo ("Right Eye Info", Range(0,1)) = 0
        _DOFBlurFlag ("DOF Blur Flag", Range(0,1)) = 1

        // === 化妆颜色 ===
        _MakeupColor1 ("Makeup Color 1", Color) = (1,1,1,1)
        _MakeupColor2 ("Makeup Color 2", Color) = (1,1,1,1)
        _MakeupColor3 ("Makeup Color 3", Color) = (1,1,1,1)
        _MakeupColor4 ("Makeup Color 4", Color) = (1,1,1,1)
        _MakeupColor5 ("Makeup Color 5", Color) = (1,1,1,1)
        _MakeupColor6 ("Makeup Color 6", Color) = (1,1,1,1)
        _EyebrowColor ("Eyebrow Color", Color) = (0,0,0,1)
        _EyeshadowColor ("Eyeshadow Color", Color) = (0,0,0,1)
        _EyelinerColor ("Eyeliner Color", Color) = (0,0,0,1)
        _LipColor ("Lip Color", Color) = (1,0,0,1)
        _BlusherColor ("Blusher Color", Color) = (1,0.5,0.5,1)
        _DecorateColor ("Decorate Color", Color) = (1,1,1,1)
        _Decorate2Color ("Decorate2 Color", Color) = (1,1,1,1)
        _MakeupMultiplyColor ("Makeup Multiply Color", Color) = (1,1,1,1)
        _EyelidColor ("Eyelid Color", Color) = (1,1,1,1)

        // === 化妆强度 & 唇部 ===
        _MakeupRoughness5 ("Makeup Roughness 5", Range(0,1)) = 0.5
        _EyebrowDensity ("Eyebrow Density", Range(0,1)) = 1
        _EyeshadowDensity ("Eyeshadow Density", Range(0,1)) = 1
        _EyelinerDensity ("Eyeliner Density", Range(0,1)) = 1
        _BlusherDensity ("Blusher Density", Range(0,1)) = 1
        _LipDensity ("Lip Density", Range(0,1)) = 1
        _LipRoughness ("Lip Roughness", Range(0,2)) = 0.5
        _LipSpecular ("Lip Specular", Range(0,2)) = 1
        _DecorateDensity ("Decorate Density", Range(0,1)) = 1
        _Decorate2Density ("Decorate2 Density", Range(0,1)) = 1

        // === 贴纸UV变换 ===
        _DecorateUV ("Decorate UV (xy=scale, zw=offset)", Vector) = (1,1,0,0)
        _Decorate2UV ("Decorate2 UV (xy=scale, zw=offset)", Vector) = (1,1,0,0)

        // === MorphPart 特效 ===
        _MorphPartColor ("MorphPart Color", Color) = (1,1,1,1)
        _MorphPartShinningColor ("MorphPart Shinning Color", Color) = (1,1,1,1)
        _MorphPartSpreadColor ("MorphPart Spread Color", Color) = (1,1,1,1)
        _MorphPartParam ("MorphPart Param", Vector) = (0,0,0,0)
        _MorphPartTexUV ("MorphPart TexUV (xy=center, z=radius)", Vector) = (0.5,0.5,0.1,0)
        _MorphPartId ("MorphPart Id", Float) = 0
        _MorphPartRange ("MorphPart Range", Float) = 0.1
        _MorphPartShinningAlpha ("MorphPart Shinning Alpha", Range(0,1)) = 0
        _MorphPartWaveLength ("MorphPart Wave Length", Float) = 1
        _MorphPartBreathAlpha ("MorphPart Breath Alpha", Range(0,1)) = 0

        // === 闪片 Sparkle ===
        _EyeSparkleColor ("Eye Sparkle Color", Color) = (1,1,1,1)
        _LipSparkleColor ("Lip Sparkle Color", Color) = (1,1,1,1)
        _EyeSparkleParams ("Eye Sparkle Params", Vector) = (0.1,0.5,0,0)
        _LipSparkleParams ("Lip Sparkle Params", Vector) = (0.1,0.5,0,0)
        _EyeSparkleSize ("Eye Sparkle Size", Vector) = (50,50,0,0)
        _LipSparkleSize ("Lip Sparkle Size", Vector) = (50,50,0,0)
        _EyeSparkle ("Eye Sparkle Intensity", Range(0,1)) = 0
        _LipSparkle ("Lip Sparkle Intensity", Range(0,1)) = 0
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" "Queue"="Geometry" }
        LOD 300

        Pass
        {
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.5

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // ============================================================
            // Constant Buffers (only project-custom ones; Unity built-ins
            // like _MainLightPosition, _Time, etc. are provided by URP Core)
            // ============================================================

            // Buffer 0: AsukaPerShader_AddLightParams_PerCamera
            CBUFFER_START(AsukaPerShader_AddLightParams_PerCamera)
                float4 _AdditionalLightPosition[30];
                float4 _AdditionalLightSpotAttenuation[30];
                half4  _AdditionalLightCount;
                half4  _AdditionalLightColor[30];
                half4  _AdditionalLightDistanceAttenuation[30];
                float4 _AdditionalLightSpotDir[30];
                half4  _AdditionalLightShadowWeight[30];
            CBUFFER_END

            // Buffer 1: AsukaPerShader_PerCamera (custom fields only;
            // _MainLightPosition/_MainLightColor are provided by URP)
            CBUFFER_START(AsukaPerShader_PerCamera)
                float4x4 hlslcc_mtx4x4_WorldToLight;
                // _MainLightPosition: already declared by URP
                // _MainLightColor: already declared by URP
                half4  _ScaledScreenParams_Custom; // renamed to avoid conflict
                half4  _GridInfo;
                float4 _AuroraGridInfo;
                half   _MainLightRealtime;
                half   _DOFEnable;
                half   _GlobalMipBias;
            CBUFFER_END

            // Buffer 2: UnityPerCamera - extra custom params
            // (standard Unity params like _Time, _ProjectionParams, _ScreenParams,
            //  _WorldSpaceCameraPos are already from URP Core)
            float3 _WorldSpaceRelativeCameraPos;
            float  _EyeAdaptionExposure;
            float  _EyeAdaptionInverseExposure;
            float3 _WorldSpaceCameraDir;
            float3 _PrevCameraPos;
            float  _ReflectNormalBias;
            float4 _PrevTime;
            float4 _SRPTime;
            float4 _PaperUnscaledTime;
            uint   _FrameCount8;

            // Buffer 3: UnityPerDraw - extra custom params
            // (unity_ObjectToWorld, unity_WorldToObject, unity_SpecCube0_HDR
            //  are already from URP Core)
            float4x4 hlslcc_mtx4x4unity_MatrixPreviousM;
            float4x4 hlslcc_mtx4x4unity_MatrixPreviousMI;
            uint   Pape_SpecCubeArrayMaxMip;

            // Buffer 4: Character_Param
            CBUFFER_START(Character_Param)
                float4 _CharLightPosition;
                half4  _CharShColor;
                half4  _CharMainLightColor;
                half4  _CharLightColor;
                half3  _RootMPosition;
                half   _CharShIntensity;
                half   _CharShadowIntensity;
                half   _CharShHeight;
                half   _ClipYValue;
                half   _HomeLightingEnable;
                half   _EyeAdaptionInverseExposureEnable;
                half4  _HomeLightingPPVScale;
                half4  _HomeLightingPPVColor0;
                half4  _HomeLightingPPVColor1;
                half4  _HomeRimLightingPPVColor;
                half   _POSMEnabled;
            CBUFFER_END

            // Buffer 5: UnityPerMaterial
            CBUFFER_START(UnityPerMaterial)
                half4  _MainTex_ST;
                half4  _Color;
                half4  _FresnelColor;
                half4  _OverlayColor;
                half4  _SparkleUV;
                half4  _SSSSkinTexture_TexelSize;
                half   _Cutoff;
                half   _ShadowIntensity;
                half   _AOIntensity;
                half   _NonMetalSpecular;
                half   _FresnelIntensity;
                half   _Fresnelpower;
                half   _LerpValue;
                half   _LeftEyeInfo;
                half   _RightEyeInfo;
                half   _DOFBlurFlag;
                half4  _MakeupColor1;
                half4  _MakeupColor2;
                half4  _MakeupColor3;
                half4  _MakeupColor4;
                half4  _MakeupColor5;
                half4  _MakeupColor6;
                half4  _DecorateUV;
                half4  _Decorate2UV;
                half4  _MorphPartColor;
                half4  _MorphPartShinningColor;
                half4  _MorphPartSpreadColor;
                half4  _MorphPartParam;
                half4  _MorphPartTexUV;
                half3  _EyebrowColor;
                half3  _EyeshadowColor;
                half3  _EyelinerColor;
                half3  _LipColor;
                half3  _BlusherColor;
                half3  _DecorateColor;
                half3  _Decorate2Color;
                half3  _MakeupMultiplyColor;
                half   _MakeupRoughness5;
                half   _EyebrowDensity;
                half   _EyeshadowDensity;
                half   _EyelinerDensity;
                half   _BlusherDensity;
                half   _LipDensity;
                half   _LipRoughness;
                half   _LipSpecular;
                half   _DecorateDensity;
                half   _Decorate2Density;
                half   _MorphPartId;
                half   _MorphPartRange;
                half   _MorphPartShinningAlpha;
                half   _MorphPartWaveLength;
                half   _MorphPartBreathAlpha;
                half4  _EyeSparkleColor;
                half4  _LipSparkleColor;
                half4  _EyeSparkleParams;
                half4  _LipSparkleParams;
                half4  _EyeSparkleSize;
                half4  _LipSparkleSize;
                half   _EyeSparkle;
                half   _LipSparkle;
                half3  _EyelidColor;
            CBUFFER_END

            // Buffer 6: PapePerRendererCB
            CBUFFER_START(PapePerRendererCB)
                half4  _SHMaps[7];
                half4  _CubeSHs[7];
                half4  _PapeRendererExtra;
                half   _PapeRendererParam0;
                half   _PapeRendererParam1;
                half   _PapeRendererParam2;
                half   _PapeRendererParam3;
                half   _PapeRendererParam4;
                half   _PapeRendererParam5;
            CBUFFER_END

            // ============================================================
            // Textures & Samplers
            // ============================================================
            // unity_SpecCube0 and samplerunity_SpecCube0 are provided by URP Core

            TEXTURE2D(_LightIndexMap);
            SAMPLER(sampler_LightIndexMap);

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);

            TEXTURE2D(_SpecularTex);
            SAMPLER(sampler_SpecularTex);

            TEXTURE2D(_NormalTex);
            SAMPLER(sampler_NormalTex);

            TEXTURE2D(_EyebrowTex);
            // shares sampler_MainTex

            TEXTURE2D(_EyeshadowTex);
            SAMPLER(sampler_EyeshadowTex);

            TEXTURE2D(_EyelinerTex);
            // shares sampler_MainTex

            TEXTURE2D(_BlusherTex);
            // shares sampler_MainTex

            TEXTURE2D(_LipTex);
            SAMPLER(sampler_LipTex);

            TEXTURE2D(_DecorateTex);
            // shares sampler_MainTex

            TEXTURE2D(_Decorate2Tex);
            // shares sampler_MainTex

            TEXTURE2D(_MorphPartTex);
            SAMPLER(sampler_MorphPartTex);

            TEXTURE2D(_EyelidTex);
            SAMPLER(sampler_EyelidTex);

            TEXTURE2D(_SSSSkinTexture);
            SAMPLER(sampler_SSSSkinTexture);

            TEXTURE2D(_ScreenShadowTexture);
            SAMPLER(sampler_ScreenShadowTexture);

            // ============================================================
            // Structures
            // ============================================================
            struct Attributes
            {
                float4 positionOS : POSITION;
                half3  normalOS   : NORMAL;
                half4  tangentOS  : TANGENT;
                float2 uv0        : TEXCOORD0;
                float2 uv1        : TEXCOORD1;
                float2 uv2        : TEXCOORD2;
                float2 uv3        : TEXCOORD3;
            };

            struct Varyings
            {
                float4 positionCS  : SV_POSITION;
                half4  uv01        : TEXCOORD0; // xy=mainUV, zw=blusherUV
                half4  uv23        : TEXCOORD1; // xy=eyeshadow/eyeliner UV, zw=eyebrow/lip UV
                float3 positionWS  : TEXCOORD2;
                half4  tbnRow0     : TEXCOORD3; // xyz=tangent row for TBN, w=viewDir.x
                half4  tbnRow1     : TEXCOORD4; // xyz=bitangent row for TBN, w=viewDir.y
                half4  tbnRow2     : TEXCOORD5; // xyz=normal row for TBN, w=viewDir.z
                float4 positionNDC : TEXCOORD6; // clip space position for screen UV
            };

            // ============================================================
            // Fragment Output
            // ============================================================
            struct FragOutput
            {
                half4 color : SV_TARGET0;
                half  dof   : SV_TARGET1;
            };

            // ============================================================
            // Helper Functions
            // ============================================================

            // Decode 2-channel normal map to 3D normal
            half3 DecodeNormalRG(half2 enc)
            {
                half2 xy = enc * 2.0h - 1.0h;
                half z = sqrt(max(1.0h - dot(xy, xy), 0.0h));
                return half3(xy, z);
            }

            // GGX NDF (optimized mobile form matching the IR)
            float SkinGGX_D(float NdotH, half roughness)
            {
                half r2 = max(roughness * roughness, 0.01h); // IR: 0xH211F ≈ 0.01
                float invR2 = 1.0 / (float)r2;
                float ggxA = (float)r2 - invR2;

                float ndh = min((float)NdotH, 0.99902344);
                float ndh2 = ndh * ndh;
                float denom = ndh2 * ggxA + invR2;
                float invDenom = 1.0 / denom;
                invDenom = min(invDenom, 10.0);
                // D = invDenom^2 * (1/pi)
                return invDenom * invDenom * 0.31830988;
            }

            // Schlick Fresnel (matching IR: lerp between specBase and grazingTerm)
            half SkinFresnel(half specBase, half grazingTerm, float VdotH)
            {
                float x = 1.0 - VdotH;
                float x2 = x * x;
                float x4 = x2 * x2;
                float x5 = x4 * x;
                return specBase * (half)(1.0 - x5) + grazingTerm * (half)x5;
            }

            // Smith-Hammon Joint Visibility Term (matching IR: sum-form denominator)
            float SkinVisibility(float NdotL, float NdotV, half roughness)
            {
                half r2 = max(roughness * roughness, 0.1h); // IR: 0xH2E66 ≈ 0.1
                float oneMinusR2 = 1.0 - (float)r2;
                float NdotV_eps = NdotV + 1e-5;
                float gv1 = NdotL * oneMinusR2 + (float)r2;
                float gv2 = NdotV_eps * oneMinusR2 + (float)r2;
                float denom = NdotL * gv2 + NdotV_eps * gv1 + 1e-5;
                float V = 0.5 / denom;
                return min(V, 10.0);
            }

            // Procedural sparkle (matching IR exactly):
            // - Dynamic neighbor selection via sign(fract-0.5)
            // - Hash inputs divided by sparkleSize
            // - Two hash channels per cell (x and y random)
            // - Distance scaled by sparkleParams.y
            // - Per-cell GGX-like lobe using sparkleParams.w and NdotH
            // Returns half4: per-cell sparkle contributions for later GGX evaluation
            half4 ComputeSparkleRaw(float2 uv, half4 sparkleSize, half4 sparkleParams, float sparkleNdotH)
            {
                // Tile coordinates
                float2 tileCoord = uv * (float2)sparkleSize.xy;
                float2 tileFloor = floor(tileCoord);
                float2 tileFract = frac(tileCoord);

                // Dynamic neighbor offset: sign(fract - 0.5)
                float2 signOff;
                signOff.x = (tileFract.x - 0.5 > 0.0) ? 1.0 : ((tileFract.x - 0.5 < 0.0) ? -1.0 : 0.0);
                signOff.y = (tileFract.y - 0.5 > 0.0) ? 1.0 : ((tileFract.y - 0.5 < 0.0) ? -1.0 : 0.0);

                // 4 candidate cells: (0,0), (signX,0), (0,signY), (signX,signY)
                float2 cell0 = tileFloor;
                float2 cell1 = tileFloor + float2(signOff.x, 0.0);
                float2 cell2 = tileFloor + float2(0.0, signOff.y);
                float2 cell3 = tileFloor + signOff;

                // Hash inputs: cell / sparkleSize (IR divides back by size)
                float2 invSize = 1.0 / (float2)sparkleSize.xy;
                float2 h0 = cell0 * invSize;
                float2 h1 = cell1 * invSize;
                float2 h2 = cell2 * invSize;
                float2 h3 = cell3 * invSize;

                // Dual-channel hash: channel A = x*y*0.4 + (x+y)*0.6, channel B = (x+y)*(x*y)
                // Then frac(val * 2627.19 + 5.381), then frac(result * 63.97)
                float4 hashA, hashB;
                // Cell 0 & 1
                float2 xy01 = float2(h0.x * h0.y, h1.x * h1.y);
                float2 sum01 = float2(h0.x + h0.y, h1.x + h1.y);
                float2 chA_01 = xy01 * 0.4 + sum01 * 0.6;
                float2 chB_01 = sum01 * xy01;
                float4 raw01 = float4(chA_01.x, chB_01.x, chA_01.y, chB_01.y);
                raw01 = frac(raw01 * 2627.19 + 5.381);
                float4 rand01 = frac(raw01 * 63.97);

                // Cell 2 & 3
                float2 xy23 = float2(h2.x * h2.y, h3.x * h3.y);
                float2 sum23 = float2(h2.x + h2.y, h3.x + h3.y);
                float2 chA_23 = xy23 * 0.4 + sum23 * 0.6;
                float2 chB_23 = sum23 * xy23;
                float4 raw23 = float4(chA_23.x, chB_23.x, chA_23.y, chB_23.y);
                raw23 = frac(raw23 * 2627.19 + 5.381);
                float4 rand23 = frac(raw23 * 63.97);

                // Random positions per cell: randX from channel A, randY from channel B
                float4 randX = float4(rand01.x, rand01.z, rand23.x, rand23.z); // chA results
                float4 randY = float4(rand01.y, rand01.w, rand23.y, rand23.w); // chB results

                // Radius check: sparkleParams.x >= randX (per cell)
                float paramX = (float)sparkleParams.x;
                half4 radiusMask = (half4)step(randX, (float4)paramX);

                // Per-cell distance scale (IR: denom_i = randX_i * (1 - sparkleParams.y) + sparkleParams.y + eps)
                float spY = (float)sparkleParams.y;
                float oneMinusSpY = 1.0 - spY;
                float4 distDenom = randX * oneMinusSpY + spY + 1e-4;
                float4 perCellScale = 1.0 / distDenom;

                // IR uses abs(fract - cellRandom) * perCellScale per component
                float2 d0 = abs(tileFract - float2(rand01.x, rand01.y)) * perCellScale.x;
                float2 d1 = abs(tileFract - float2(rand01.z, rand01.w) - float2(signOff.x, 0)) * perCellScale.y;
                float2 d2 = abs(tileFract - float2(rand23.x, rand23.y) - float2(0, signOff.y)) * perCellScale.z;
                float2 d3 = abs(tileFract - float2(rand23.z, rand23.w) - signOff) * perCellScale.w;

                half4 dist2 = half4(
                    (half)dot(d0, d0),
                    (half)dot(d1, d1),
                    (half)dot(d2, d2),
                    (half)dot(d3, d3)
                );

                // Falloff: max(0, 1 - dist2 * 4)
                half4 falloff = max(-dist2 * 4.0h + 1.0h, 0.0h);

                // Apply radius mask
                falloff *= radiusMask;

                // Per-cell GGX-like sparkle lobe using sparkleParams.w and NdotH
                // IR: applies fract(randY * params.z + sparkleNdotH), then abs*2, then GGX-like
                half4 lobeInput = (half4)frac(float4(randY) * (float)sparkleParams.z + sparkleNdotH);
                half4 lobeVal = abs(lobeInput - 0.5h) * 2.0h;

                // GGX-like distribution on the sparkle lobe (using sparkleParams.w as roughness²)
                half sparkleR2 = max(sparkleParams.w * sparkleParams.w, 0.01h);
                half sparkleInvR2 = 1.0h / sparkleR2;
                half sparkleGgxA = sparkleR2 - sparkleInvR2;

                float4 lobeF = min((float4)lobeVal, 0.99902344);
                float4 lobe2 = lobeF * lobeF;
                float4 lobeDenom = lobe2 * (float)sparkleGgxA + (float)sparkleInvR2;
                float4 lobeInv = 1.0 / lobeDenom;
                lobeInv = min(lobeInv, 10.0);
                float4 lobeD = lobeInv * lobeInv * 0.31830988;

                // Combine: falloff * lobeD, then sum all 4 cells
                half4 cellContrib = falloff * (half4)lobeD;
                half sparkleTotal = dot(cellContrib, (half4)1.0h);

                return half4(sparkleTotal, 0, 0, 0);
            }

            // Pape SH evaluation (matching IR basis exactly)
            half3 EvaluatePapeSH(half3 N)
            {
                half4 n4 = half4(N.x, N.y, N.z, 1.0h);

                half3 linear_sh;
                linear_sh.r = dot(_SHMaps[0], n4);
                linear_sh.g = dot(_SHMaps[1], n4);
                linear_sh.b = dot(_SHMaps[2], n4);

                half4 quadBasis = half4(
                    N.y * N.x,
                    N.z * N.y,
                    N.z * N.z,
                    N.x * N.z
                );

                half3 quad_sh;
                quad_sh.r = dot(_SHMaps[3], quadBasis);
                quad_sh.g = dot(_SHMaps[4], quadBasis);
                quad_sh.b = dot(_SHMaps[5], quadBasis);

                half nx2MinusNy2 = N.x * N.x - N.y * N.y;

                return max(linear_sh + quad_sh + _SHMaps[6].rgb * nx2MinusNy2, 0.0h);
            }

            // Unity HDR cubemap decode (matching IR exactly)
            half3 DecodeHDRCubemap(half4 encoded, float4 hdr)
            {
                float decodeArg = hdr.w * ((float)encoded.a - 1.0) + 1.0;
                decodeArg = max(decodeArg, 0.0);
                float decodeScale = (decodeArg > 0.0)
                    ? hdr.x * exp2(hdr.y * log2(decodeArg))
                    : 0.0;
                return encoded.rgb * (half)decodeScale;
            }

            // Roughness to cubemap mip level (matching IR: r*(1.7-0.7*r)*6)
            half PerceptualRoughnessToMip(half roughness)
            {
                return roughness * (1.7001953125h - 0.7001953125h * roughness) * 6.0h;
            }

            // MorphPart effect (matching IR exactly: additive contribution after makeup chain)
            // Returns the three additive MorphPart terms to be added to albedo after all makeup layers.
            // IR: uses _MorphPartTexUV as UV ST for sampling, _MorphPartParam.xy as center,
            //     _MorphPartParam.z as radius, _MorphPartWaveLength as smoothstep range,
            //     _MorphPartRange as ID threshold.
            void ComputeMorphPart(float2 uv, out half3 term1, out half3 term2, out half3 term3)
            {
                // IR field 28 = _MorphPartTexUV used as UV ST for sampling
                float2 morphUV = uv * (float2)_MorphPartTexUV.xy + (float2)_MorphPartTexUV.zw;
                half4 morphTex = SAMPLE_TEXTURE2D(_MorphPartTex, sampler_MorphPartTex, morphUV);

                // ID matching: morphTex.r * 255 compared against _MorphPartId
                // IR: threshold is _MorphPartRange (field 48), NOT _MorphPartShinningAlpha
                half scaledId = morphTex.r * 255.0h;
                half idDiff = abs(scaledId - _MorphPartId);
                half idMask = (_MorphPartRange >= idDiff) ? morphTex.g : 0.0h;

                // Distance/smoothstep mask using _MorphPartParam.xy as center, .z as radius
                // IR: range for smoothstep is _MorphPartWaveLength (field 50)
                float2 diff = (float2)_MorphPartParam.xy - uv;
                float dist = length(diff) - (float)_MorphPartParam.z;
                half absDist = (half)abs(dist);
                half range = _MorphPartWaveLength;
                half t = saturate((range - absDist) / max(range, 0.001h));
                half smoothstepMask = t * t * (3.0h - 2.0h * t);

                // Three additive terms (IR lines 1208-1210):
                // term1 = _MorphPartColor.rgb * _MorphPartBreathAlpha * idMask
                term1 = _MorphPartColor.rgb * _MorphPartBreathAlpha * idMask;
                // term2 = morphTex.g * _MorphPartSpreadColor.rgb * smoothstepMask
                term2 = (half3)(morphTex.g * _MorphPartSpreadColor.rgb) * smoothstepMask;
                // term3 = _MorphPartShinningColor.rgb * _MorphPartShinningAlpha * idMask
                term3 = _MorphPartShinningColor.rgb * _MorphPartShinningAlpha * idMask;
            }

            // ============================================================
            // Vertex Shader
            // ============================================================
            Varyings vert(Attributes input)
            {
                Varyings output = (Varyings)0;

                float3 posWS = TransformObjectToWorld(input.positionOS.xyz);
                output.positionCS = TransformWorldToHClip(posWS);
                output.positionWS = posWS;
                output.positionNDC = output.positionCS;

                // UVs
                output.uv01.xy = (half2)input.uv0;
                output.uv01.zw = (half2)input.uv1;  // blusher UV
                output.uv23.xy = (half2)input.uv2;  // eyeshadow/eyeliner UV
                output.uv23.zw = (half2)input.uv3;  // eyebrow/lip UV

                // TBN
                half3 normalWS = (half3)TransformObjectToWorldNormal(input.normalOS);
                half3 tangentWS = (half3)TransformObjectToWorldDir(input.tangentOS.xyz);
                half3 bitangentWS = cross(normalWS, tangentWS) * input.tangentOS.w;

                // View direction stored in .w components
                float3 viewDir = _WorldSpaceCameraPos - posWS;
                half3 viewDirH = (half3)normalize(viewDir);

                output.tbnRow0 = half4(tangentWS.x, bitangentWS.x, normalWS.x, viewDirH.x);
                output.tbnRow1 = half4(tangentWS.y, bitangentWS.y, normalWS.y, viewDirH.y);
                output.tbnRow2 = half4(tangentWS.z, bitangentWS.z, normalWS.z, viewDirH.z);

                return output;
            }

            // ============================================================
            // Fragment Shader
            // ============================================================
            FragOutput frag(Varyings input)
            {
                FragOutput output = (FragOutput)0;

                // ========================================
                // Stage 1: Texture Sampling & Makeup Compositing
                // ========================================
                float2 mainUV = (float2)input.uv01.xy;
                float2 blusherUV = (float2)input.uv01.zw;
                float2 eyeshadowUV = (float2)input.uv23.xy;
                float2 eyebrowLipUV = (float2)input.uv23.zw; // IR: TEXCOORD1.zw for eyebrow & lip

                // Sample specular texture
                half4 specTex = SAMPLE_TEXTURE2D(_SpecularTex, sampler_SpecularTex, mainUV);

                // Sample main texture with mip bias
                half4 mainTex = SAMPLE_TEXTURE2D_BIAS(_MainTex, sampler_MainTex, mainUV, _GlobalMipBias);

                // Base albedo
                half3 albedo = mainTex.rgb * _Color.rgb;

                // --- Eye region detection for sparkle ---
                half eyeRegionSelect = (input.uv01.y <= 0.5h) ? 1.0h : 0.0h;

                // --- Eyebrow layer (uses eyebrowLipUV per IR) ---
                half4 eyebrowTex = SAMPLE_TEXTURE2D(_EyebrowTex, sampler_MainTex, eyebrowLipUV);
                half eyebrowMask = saturate(eyebrowTex.a * _EyebrowDensity);
                albedo = lerp(albedo, eyebrowTex.rgb * _EyebrowColor, eyebrowMask);

                // --- Eyeshadow layer (with _MakeupMultiplyColor per IR) ---
                half4 eyeshadowTex = SAMPLE_TEXTURE2D(_EyeshadowTex, sampler_EyeshadowTex, eyeshadowUV);
                half eyeshadowMask = eyeshadowTex.a * _EyeshadowDensity;
                albedo = lerp(albedo, eyeshadowTex.rgb * _EyeshadowColor * _MakeupMultiplyColor, eyeshadowMask);

                // --- Eyeliner layer (with _MakeupMultiplyColor per IR) ---
                half4 eyelinerTex = SAMPLE_TEXTURE2D(_EyelinerTex, sampler_MainTex, eyeshadowUV);
                half eyelinerMask = eyelinerTex.a * _EyelinerDensity;
                albedo = lerp(albedo, eyelinerTex.rgb * _EyelinerColor * _MakeupMultiplyColor, eyelinerMask);

                // --- Blusher layer (multiplicative tint per IR) ---
                half4 blusherTex = SAMPLE_TEXTURE2D(_BlusherTex, sampler_MainTex, blusherUV);
                half blusherMask = saturate(blusherTex.a * _BlusherDensity);
                albedo *= lerp((half3)1.0h, blusherTex.rgb * _BlusherColor, blusherMask);

                // --- Lip layer (uses eyebrowLipUV, with _MakeupMultiplyColor per IR) ---
                half4 lipTex = SAMPLE_TEXTURE2D(_LipTex, sampler_LipTex, eyebrowLipUV);
                half lipMask = lipTex.a * _LipDensity;
                albedo = lerp(albedo, lipTex.rgb * _LipColor * _MakeupMultiplyColor, lipMask);

                // --- Decorate layer 1 (IR: UV based on blusherUV with offset+scale) ---
                // IR: decorateUV = (blusherUV + _DecorateUV.xy - 0.5) * _DecorateUV.z + 0.5
                float2 decorateUV = saturate((blusherUV + (float2)_DecorateUV.xy - 0.5) * (float)_DecorateUV.z + 0.5);
                half4 decorateTex = SAMPLE_TEXTURE2D(_DecorateTex, sampler_MainTex, decorateUV);
                half decorateMask = decorateTex.a * _DecorateDensity;
                albedo = lerp(albedo, decorateTex.rgb * _DecorateColor * _MakeupMultiplyColor, decorateMask);

                // --- Decorate layer 2 (IR: UV based on blusherUV with offset+scale) ---
                float2 decorate2UV = saturate((blusherUV + (float2)_Decorate2UV.xy - 0.5) * (float)_Decorate2UV.z + 0.5);
                half4 decorate2Tex = SAMPLE_TEXTURE2D(_Decorate2Tex, sampler_MainTex, decorate2UV);
                half decorate2Mask = decorate2Tex.a * _Decorate2Density;
                albedo = lerp(albedo, decorate2Tex.rgb * _Decorate2Color * _MakeupMultiplyColor, decorate2Mask);

                // --- MorphPart (additive, after all makeup layers per IR lines 1208-1210) ---
                half3 morphTerm1, morphTerm2, morphTerm3;
                ComputeMorphPart(mainUV, morphTerm1, morphTerm2, morphTerm3);
                albedo += morphTerm1;
                albedo += morphTerm2;
                albedo += morphTerm3;

                // --- Roughness & Specular (lip override) ---
                // lipTex.a directly controls lip material override (NOT lipMask which includes density)
                half lipRoughnessBlend = lipTex.a * (_LipRoughness - 1.0h) + 1.0h;
                half lipSpecularBlend = lipTex.a * (_LipSpecular - 1.0h) + 1.0h;
                half perceptualRoughness = max(specTex.r * lipRoughnessBlend, 0.01h); // IR: 0xH211F ≈ 0.01
                half specMask = specTex.b * lipSpecularBlend;

                // ========================================
                // Stage 1.4: Sparkle Computation
                // ========================================
                // Eye sparkle parameters
                half eyeSparkleStrength = mainTex.a * _EyeSparkle;

                // Lip sparkle parameters
                half lipSparkleStrength = lipTex.a * _LipSparkle;

                // Region-based selection (IR: lerp(eye, lip, eyeRegionSelect))
                half sparkleStrength = lerp(eyeSparkleStrength, lipSparkleStrength, eyeRegionSelect);
                half4 activeSparkleParams = lerp(_EyeSparkleParams, _LipSparkleParams, eyeRegionSelect);
                half4 activeSparkleSize = lerp(_EyeSparkleSize, _LipSparkleSize, eyeRegionSelect);
                half3 activeSparkleColor = lerp(_EyeSparkleColor.rgb, _LipSparkleColor.rgb, eyeRegionSelect);

                // ========================================
                // Stage 2: Normal Reconstruction
                // ========================================
                half4 normalTexSample = SAMPLE_TEXTURE2D_BIAS(_NormalTex, sampler_NormalTex, mainUV, _GlobalMipBias);

                // Decode two normals from _NormalTex (xy and zw)
                half3 normalA = DecodeNormalRG(normalTexSample.xy);
                half3 normalB = DecodeNormalRG(normalTexSample.zw);

                // Decode eyelid normal (IR uses TEXCOORD1.xy = eyeshadowUV)
                half4 eyelidTexSample = SAMPLE_TEXTURE2D(_EyelidTex, sampler_EyelidTex, eyeshadowUV);
                half3 eyelidNormal = DecodeNormalRG(eyelidTexSample.xy);

                // Eye region blend factor
                half eyeSelect = (input.uv01.x >= 0.5h) ? 1.0h : 0.0h;
                half lerpFactor = _LeftEyeInfo * eyeSelect + _RightEyeInfo * (1.0h - eyeSelect);

                // Blend normals
                half3 blended1 = lerp(normalA, eyelidNormal, eyelidTexSample.a);
                half3 finalTangentNormal = lerp(blended1, normalB, lerpFactor);

                // TBN transform to world space
                // IR uses: N.x * TEXCOORD4 + N.y * TEXCOORD5 + N.z * TEXCOORD3
                half3 worldNormal;
                worldNormal.x = dot(half3(input.tbnRow0.x, input.tbnRow0.y, input.tbnRow0.z), finalTangentNormal);
                worldNormal.y = dot(half3(input.tbnRow1.x, input.tbnRow1.y, input.tbnRow1.z), finalTangentNormal);
                worldNormal.z = dot(half3(input.tbnRow2.x, input.tbnRow2.y, input.tbnRow2.z), finalTangentNormal);
                worldNormal = normalize(worldNormal);

                // ========================================
                // Stage 3: View & Screen Space Calculations
                // ========================================
                // View direction (from .w components)
                half3 viewDir = normalize(half3(input.tbnRow0.w, input.tbnRow1.w, input.tbnRow2.w));

                // Screen UV from clip space
                float2 screenUV;
                screenUV.x = input.positionNDC.x / input.positionNDC.w;
                screenUV.y = input.positionNDC.y * _ProjectionParams.x / input.positionNDC.w;
                screenUV = screenUV * 0.5 + 0.5;

                // Core dot products
                half NdotV = max(dot(worldNormal, viewDir), 0.0h);

                // ========================================
                // Stage 4: Main Light Shading (GGX)
                // ========================================
                half3 mainLightDir = (half3)normalize(_MainLightPosition.xyz);
                half NdotL_main = max(dot(worldNormal, mainLightDir), 0.0h); // IR: floor = 0

                // Half vector
                half3 H_main = normalize(mainLightDir + viewDir);
                half NdotH_main = saturate(dot(worldNormal, H_main));
                half VdotH_main = saturate(dot(viewDir, H_main));

                // GGX D term
                float D_main = SkinGGX_D(NdotH_main, perceptualRoughness);

                // Fresnel - IR uses: specBase = specMask * _NonMetalSpecular * 0.08
                //                    grazingTerm = saturate(specMask * _NonMetalSpecular * 4.0)
                half specNMS = specMask * _NonMetalSpecular;
                half F0 = specNMS * 0.08h;
                half F0_grazing = (half)saturate((float)specNMS * 4.0);
                half F_main = SkinFresnel(F0, F0_grazing, (float)VdotH_main);

                // Visibility term
                float V_main = SkinVisibility((float)NdotL_main, (float)NdotV, perceptualRoughness);

                // Screen shadow sampling
                half4 screenShadow = SAMPLE_TEXTURE2D(_ScreenShadowTexture, sampler_ScreenShadowTexture, screenUV);
                half shadowAtten = lerp(1.0h, screenShadow.r, _CharShadowIntensity);

                // Main light specular (full GGX D*V*F, gated by NdotL_main > 0)
                // IR: main light specular uses NdotL_main * _CharMainLightColor as color carrier
                half mainSpecScalar = (half)(D_main * V_main) * F_main;
                half3 mainSpecColor = (NdotL_main > 0.0h)
                    ? (NdotL_main * _CharMainLightColor.rgb * mainSpecScalar)
                    : half3(0, 0, 0);

                // Sparkle contribution from main light (IR: sparkle * _CharMainLightColor)
                half sparkleNdotH_main = dot(worldNormal, H_main) * 0.5h + 0.5h;
                half4 sparkleRaw_main = ComputeSparkleRaw(mainUV, activeSparkleSize, activeSparkleParams, (float)sparkleNdotH_main);
                half sparkleMask_main = sparkleRaw_main.x * sparkleStrength;
                half3 sparkleColor_main = sparkleMask_main * activeSparkleColor;

                // ========================================
                // Stage 5: Additional Lights Loop (up to 4)
                // ========================================
                half3 addLightContribution = half3(0, 0, 0);

                // Sample light index map (IR: UV = (worldPos.xz - _GridInfo.xy) / _GridInfo.zw)
                float2 lightMapUV = (input.positionWS.xz - (float2)_GridInfo.xy) / (float2)_GridInfo.zw;
                half4 lightIndexTex = SAMPLE_TEXTURE2D(_LightIndexMap, sampler_LightIndexMap, lightMapUV);
                float4 lightIndices = floor((float4)lightIndexTex * 255.0 + 0.5);

                // Pre-read shadow weights for up to 4 lights
                [unroll]
                for (int li = 0; li < 4; li++)
                {
                    float lightIdx = 0;
                    if (li == 0) lightIdx = lightIndices.r;
                    else if (li == 1) lightIdx = lightIndices.g;
                    else if (li == 2) lightIdx = lightIndices.b;
                    else lightIdx = lightIndices.a;

                    // IR: 255 is "no light" sentinel → early stop
                    if (lightIdx >= 255.0) break;

                    int idx = (int)lightIdx;

                    // Shadow weight: if idx < 30 use array lookup, else fallback
                    // IR fallback: shadowRaw = 1.0, so addShadow = 1 - _CharShadowIntensity
                    half shadowRaw = 1.0h;
                    if (idx < 30)
                    {
                        half4 sw = _AdditionalLightShadowWeight[idx];
                        shadowRaw = dot(1.0h - screenShadow, sw);
                    }
                    half addShadow = 1.0h - _CharShadowIntensity * shadowRaw;

                    // Clamp idx for array access safety
                    idx = min(idx, 29);

                    // Light position & direction
                    float4 lightPosData = _AdditionalLightPosition[idx];
                    float3 lightVec = lightPosData.xyz - input.positionWS * lightPosData.w;
                    float dist2 = dot(lightVec, lightVec);
                    float3 lightDir = lightVec * rsqrt(max(dist2, 1e-35));

                    // Distance attenuation
                    half4 distAtten = _AdditionalLightDistanceAttenuation[idx];
                    float rangeFactor = dist2 * (float)distAtten.x + 1.0;
                    float distFalloff = saturate(dist2 * (float)distAtten.y + (float)distAtten.z);

                    // Spot attenuation
                    float3 spotDir = _AdditionalLightSpotDir[idx].xyz;
                    float spotDot = dot(spotDir, lightDir);
                    float4 spotAtten = _AdditionalLightSpotAttenuation[idx];
                    float spotFalloff = saturate(spotDot * spotAtten.x + spotAtten.y);
                    spotFalloff *= spotFalloff;

                    // Combined attenuation
                    float lightAtten = distFalloff * spotFalloff / max(rangeFactor, 0.001);

                    // Light color
                    half4 lightColor = _AdditionalLightColor[idx];

                    // NdotL
                    half NdotL_add = max(dot(worldNormal, (half3)lightDir), 0.0h);

                    // Base diffuse term: lightColor * NdotL * attenuation
                    // IR does NOT have an independent albedo*diffuse term for additional lights;
                    // instead this base is used as multiplier for the simplified specular
                    half3 addBase = lightColor.rgb * NdotL_add * (half)lightAtten;

                    // Specular (simplified per IR: D * (roughness*0.25+0.25) * specBase)
                    half3 H_add = normalize((half3)lightDir + viewDir);
                    half NdotH_add = saturate(dot(worldNormal, H_add));

                    float D_add = SkinGGX_D(NdotH_add, perceptualRoughness);
                    // IR uses: specFactor = D * (perceptualRoughness * 0.25 + 0.25) * specBase
                    // where specBase = specMask * _NonMetalSpecular * 0.08 = F0
                    half roughnessScale = perceptualRoughness * 0.25h + 0.25h;
                    half specFactor_add = (half)D_add * roughnessScale;
                    // Multiply by specBase (%433 in IR = F0)
                    half specScalar_add = specFactor_add * F0;

                    half3 addSpecular = addBase * specScalar_add;

                    // Sparkle branch: if lightColor.w == -1, add sparkle contribution
                    if (lightColor.w == -1.0h)
                    {
                        half sparkleNdotH_add = dot(worldNormal, H_add) * 0.5h + 0.5h;
                        half4 sparkleRaw_add = ComputeSparkleRaw(mainUV, activeSparkleSize, activeSparkleParams, (float)sparkleNdotH_add);
                        half sparkleMask_add = sparkleRaw_add.x * sparkleStrength;
                        addSpecular += sparkleMask_add * activeSparkleColor * lightColor.rgb;
                    }

                    addLightContribution += addSpecular * addShadow;
                }

                // ========================================
                // Stage 6: Indirect Lighting / IBL + Character Light
                // ========================================

                // 6.1 Indirect Diffuse (Pape SH)
                half3 shIrradiance = EvaluatePapeSH(worldNormal);

                // 6.2 Indirect Specular (Cubemap IBL)
                half3 reflDir = reflect(-viewDir, worldNormal);
                half mipLevel = PerceptualRoughnessToMip(perceptualRoughness);
                half4 encodedCube = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, (float3)reflDir, (float)mipLevel);
                half3 decodedCube = DecodeHDRCubemap(encodedCube, unity_SpecCube0_HDR);

                // Spec scale from material (IR: specMask * _NonMetalSpecular * 0.08 = F0)
                half3 envSpecular = decodedCube * shIrradiance * F0 * _CharShIntensity;

                // 6.3 Character Light (IR: only specular, diffuse is in SSS)
                half3 charLightDir = (half3)normalize(_CharLightPosition.xyz);
                half charNdotL = max(dot(worldNormal, charLightDir), 0.0h);

                // Character light specular (full GGX D*V*F, color carrier = _CharLightColor * charNdotL)
                // IR: gated by charNdotL > 0
                half3 H_char = normalize(charLightDir + viewDir);
                half NdotH_char = saturate(dot(worldNormal, H_char));
                half VdotH_char = saturate(dot(viewDir, H_char));
                float D_char = SkinGGX_D(NdotH_char, perceptualRoughness);
                half F_char = SkinFresnel(F0, F0_grazing, (float)VdotH_char);
                float V_char = SkinVisibility((float)charNdotL, (float)NdotV, perceptualRoughness);
                half charSpecScalar = (half)(D_char * V_char) * F_char;
                half3 charSpecular = (charNdotL > 0.0h)
                    ? (_CharLightColor.rgb * charNdotL * charSpecScalar)
                    : half3(0, 0, 0);

                // Character shadow
                half charShadow = lerp(1.0h, screenShadow.r, _CharShadowIntensity);

                // ========================================
                // Stage 7: Final Compositing & Output
                // ========================================

                // SSS skin texture (screen space, pre-integrated: already contains
                // main light NdotL * lightColor * shadow after subsurface blur)
                half4 sssSkin = SAMPLE_TEXTURE2D(_SSSSkinTexture, sampler_SSSSkinTexture, screenUV);

                // Eyelid color tinting on albedo before SSS multiplication (per IR)
                // IR: tintedAlbedo = albedo * lerp(lerp(_EyelidColor, 1, eyelidTex.z), 1, lerpFactor)
                half3 eyelidBlend = lerp(_EyelidColor, (half3)1.0h, eyelidTexSample.z);
                half3 tintedAlbedo = albedo * lerp(eyelidBlend, (half3)1.0h, lerpFactor);

                // IR compositing order:
                // 1. sparkleAndSpec = sparkle * _CharMainLightColor + mainSpec
                half3 sparkleAndSpec = sparkleColor_main * _CharMainLightColor.rgb + mainSpecColor;

                // 2. charShadowBlock = charShadow * sparkleAndSpec
                half3 charShadowBlock = charShadow * sparkleAndSpec;

                // 3. sssBlock = tintedAlbedo * sssSkin + charShadowBlock
                half3 sssBlock = tintedAlbedo * sssSkin.rgb + charShadowBlock;

                // 4. charLightSpec * screenShadow.a + sssBlock
                half3 finalColor = charSpecular * screenShadow.a + sssBlock;

                // 5. envSpecular * _CharShIntensity + result
                finalColor += envSpecular;

                // 6. additionalLights + result
                finalColor += addLightContribution;

                // DOF alpha output
                half dofAlpha = lerp(1.0h, _DOFBlurFlag, _DOFEnable);

                output.color = half4(finalColor, dofAlpha);
                output.dof = dofAlpha;

                return output;
            }

            ENDHLSL
        }
    }

    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
