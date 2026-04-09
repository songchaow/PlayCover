//
// Auto-generated MSL source by PlayTools IRToMSLConverter
// E-004e: LLVM IR → MSL stub conversion
// Generated at: 2026-04-08T18:12:22Z
// Functions: 1
//

#include <metal_stdlib>
using namespace metal;

struct FGlobals_Type {
    float4 _Time;
    float3 _WorldSpaceCameraPos;
    float4 _ProjectionParams;
    float4 _ZBufferParams;
    float4 _mhyWorldOffset;
    float4 hlslcc_mtx4x4unity_WorldToCamera[4];
    float4 _WorldSpaceLightPos0;
    half4 unity_SHAr;
    half4 unity_SHAg;
    half4 unity_SHAb;
    half4 unity_SHBr;
    half4 unity_SHBg;
    half4 unity_SHBb;
    half4 unity_SHC;
    half4 _LightColor0;
    float4 _mhyMainLightParam;
    float4 hlslcc_mtx4x4_MHYWorldToLightCookie[4];
    float4 _ES_MainLightIntensityIncreaseParams;
    float4 _ColorGradingProfileArray[12];
    float4 _MainLightClipPlaneBaseParamsList[4];
    float _MainLightClipPlaneAlphas[4];
    uint _MainLightClipPlaneCount;
    float4 _CameraDepthTexture_TexelSize;
    float4 _BlurKernel;
    half _ElementViewEleDrawOn;
    half4 _ElementViewSceneBackgroundColor;
    half3 _ElementViewSceneLightColor;
    half4 _ElementViewEleColors[16];
    float4 _ElementViewParamsFloat1;
    float4 _ElementViewParamsFloat2;
    float4 _ElementViewParamsFloat3;
    half4 _ElementViewParamsHalf1;
    half4 _ElementViewParamsHalf2;
    half4 _ElementViewParamsHalf3;
    half _SpecialElementViewID;
    half _ShamanViewOn;
    half3 _ShamanViewWaveColorA;
    half3 _ShamanViewWaveColorB;
    half3 _ShamanViewDarkenColor;
    float _ShamanViewSymbolScale;
    float _ShamanSymbolBreathSpeed;
    float _ShamanViewRandomX;
    float _ShamanViewRandomY;
    int _ShamanViewXpattern;
    int _ShamanViewYpattern;
    float _waveSymbolScale;
    float4 _ShamanSymbolMaskUV;
    float _ShamanViewOffset;
    float _ShamanViewLength;
    half3 _ES_SceneFrontRimColor;
    half4 _SandGliter_TillPowerGamma;
    half _StaticObjectRimWidthScaleReverse;
};

constexpr sampler __air_sampler_state(coord::normalized, address::clamp_to_edge, filter::linear);

struct XlatMtlMain_Out {
    half4 SV_Target0 [[color(0)]];
    half4 SV_Target1 [[color(1)]];
};

struct XlatMtlMain_StageIn {
    float4 TEXCOORD0;
    float3 TEXCOORD1;
};

// [0] fragment: xlatMtlMain
// air builtins: air.sample_texture_2d → sample, air.convert → (type_cast), air.fma → fma, air.fast_floor → floor, air.fast_trunc → trunc, air.dot → dot, air.fast_rsqrt → rsqrt, air.fmax → fmax, air.sample_texture_cube → sample, air.fast_clamp → clamp, air.fast_exp2 → exp2, air.fast_fabs → abs, air.clamp → clamp, air.fast_fmax → fmax, air.fast_fmin → fmin, air.rsqrt → rsqrt, air.log2 → log2, air.exp2 → exp2, air.fmin → fmin, air.min.u → min, air.fast_log2 → log2, air.fast_sqrt → sqrt, air.fast_fract → fract, air.fabs → abs, air.fast_sin → sin, air.max.s → max
fragment XlatMtlMain_Out xlatMtlMain(const constant FGlobals_Type& __restrict FGlobals [[buffer(0)]], sampler sampler_ShadowMapTexture [[sampler(0)]], sampler sampler_MHYLightTexture0 [[sampler(1)]], sampler sampler_CameraNormalsTexture [[sampler(2)]], sampler sampler_CameraAlbedoTexture [[sampler(3)]], sampler sampler_CameraSpecularTexture [[sampler(4)]], sampler sampler_CameraColorGradingVolumeMaskTexture [[sampler(5)]], sampler sampler_CameraDepthTexture [[sampler(6)]], sampler sampler_AOHalfTexture [[sampler(7)]], sampler sampler_ElementViewScenePatternTex [[sampler(8)]], sampler sampler_ElementViewSceneWaveTex [[sampler(9)]], sampler sampler_ElementViewElePatternTex [[sampler(10)]], texture2d<half> _CameraNormalsTexture [[texture(0)]], texture2d<half> _CameraAlbedoTexture [[texture(1)]], texture2d<half> _CameraSpecularTexture [[texture(2)]], texture2d<float> _CameraDepthTexture [[texture(3)]], texture2d<half> _CameraColorGradingVolumeMaskTexture [[texture(4)]], texture2d<half> _ShadowMapTexture [[texture(5)]], texturecube<half> _MHYLightTexture0 [[texture(6)]], texture2d<half> _AOHalfTexture [[texture(7)]], texture2d<half> _ElementViewElePatternTex [[texture(8)]], texture2d<half> _ElementViewSceneWaveTex [[texture(9)]], texture2d<half> _ElementViewScenePatternTex [[texture(10)]], texture2d<half> _DeferredToonRampTex [[texture(11)]], XlatMtlMain_StageIn stageIn [[stage_in]]) {
    float3 phi_0; // phi pre-decl
    float3 phi_1; // phi pre-decl
    float3 phi_2; // phi pre-decl
    int phi_3; // phi pre-decl
    half phi_4; // phi pre-decl
    half phi_5; // phi pre-decl
    half2 phi_6; // phi pre-decl
    half3 phi_7; // phi pre-decl
    half3 phi_8; // phi pre-decl
    half3 phi_9; // phi pre-decl
    float3 phi_10; // phi pre-decl
    half3 phi_11; // phi pre-decl
    float phi_12; // phi pre-decl
    half3 phi_13; // phi pre-decl
    float3 phi_14; // phi pre-decl
    half3 phi_15; // phi pre-decl
    half3 phi_16; // phi pre-decl
    half3 phi_17; // phi pre-decl
    half4 phi_18; // phi pre-decl
    half4 phi_19; // phi pre-decl
    auto t20 = stageIn.TEXCOORD0.xy;
    auto t21 = _CameraNormalsTexture.sample(sampler_CameraNormalsTexture, t20);
    auto t22 = t21.wxyz;
    auto t23 = float4(t22);
    auto t24 = _CameraAlbedoTexture.sample(sampler_CameraAlbedoTexture, t20);
    auto t25 = _CameraSpecularTexture.sample(sampler_CameraSpecularTexture, t20);
    auto t26 = t23.yzw;
    auto t27 = fma(t26, float3(2.0, 2.0, 2.0), float3(-1, -1, -1));
    auto t28 = half3(t27);
    half4 t29 = half4(t28[0], t28[1], t28[2], 0);
    auto t30 = t25.w;
    float t31 = float(t30);
    auto t32 = fma(t31, 255, 0.5);
    auto t33 = floor(t32);
    auto t34 = _CameraDepthTexture.sample(sampler_CameraDepthTexture, t20);
    auto t35 = t34.x;
    float4 t36 = FGlobals._ZBufferParams;
    auto t37 = t36.x;
    auto t38 = t36.y;
    auto t39 = fma(t37, t35, t38);
    float t40 = 1.0 / t39;
    auto t41 = _CameraColorGradingVolumeMaskTexture.sample(sampler_CameraColorGradingVolumeMaskTexture, t20);
    half2 t42 = half2(t41.x);
    half2 t43 = t42 * half2(3.98438, 4.04688);
    auto t44 = t43.x;
    float t45 = float(t44);
    auto t46 = trunc(t45);
    float t47 = 0.0 - t46;
    auto t48 = t43.y;
    float t49 = float(t48);
    auto t50 = fma(t47, 1.01587, t49);
    auto t51 = int(t46);
    auto t52 = int(t33);
    auto t53 = t24.w;
    bool t54 = t53 < 0.509766;
    bool t55 = t53 > 0.449951;
    bool t56 = t55 & t54;
    int3 t57 = 0;
    t57.x = t52;
    int3 t58 = int3(t57.x);
    bool3 t59 = t58 == int3(11, 13, 1.0);
    uchar3 t60 = uchar3(t59);
    auto t61 = t60.y;
    auto t62 = t60.x;
    uint8_t t63 = t62 | t61;
    auto t64 = t60.z;
    uint8_t t65 = t63 | t64;
    bool t66 = t65 != 0;
    bool t67 = t56 & t66;
    float t68 = t67 ? 0.0 : t50;
    float3 t69 = 0;
    t69.x = t68;
    float3 t70 = 0;
    t70.x = t40;
    float3 t71 = float3(t70.x);
    float3 t72 = FGlobals._WorldSpaceCameraPos;
    auto t73 = fma(stageIn.TEXCOORD1, t71, t72);
    float4 t74 = float4(t73[0], t73[1], t73[2], 0);
    auto t75 = dot(stageIn.TEXCOORD1, stageIn.TEXCOORD1);
    auto t76 = rsqrt(t75);
    float3 t77 = 0;
    t77.x = t76;
    float3 t78 = float3(t77.x);
    float3 t79 = t78 * stageIn.TEXCOORD1;
    auto t80 = _ShadowMapTexture.sample(sampler_ShadowMapTexture, t20);
    auto t81 = t80.x;
    float t82 = float(t81);
    half4 t83 = t29;
    t83.w = 1.0;
    half4 t84 = FGlobals.unity_SHAr;
    auto t85 = dot(t84, t83);
    half4 t86 = 0;
    t86.x = t85;
    half4 t87 = FGlobals.unity_SHAg;
    auto t88 = dot(t87, t83);
    half4 t89 = t86;
    t89.y = t88;
    half4 t90 = FGlobals.unity_SHAb;
    auto t91 = dot(t90, t83);
    half4 t92 = t89;
    t92.z = t91;
    auto t93 = t83.yzzx;
    auto t94 = t83.xyzz;
    half4 t95 = t93 * t94;
    half4 t96 = FGlobals.unity_SHBr;
    auto t97 = dot(t96, t95);
    half4 t98 = 0;
    t98.x = t97;
    half4 t99 = FGlobals.unity_SHBg;
    auto t100 = dot(t99, t95);
    half4 t101 = t98;
    t101.y = t100;
    half4 t102 = FGlobals.unity_SHBb;
    auto t103 = dot(t102, t95);
    half4 t104 = t101;
    t104.z = t103;
    auto t105 = t28.y;
    auto t106 = t28.x;
    half t107 = t105 * t105;
    half t108 = 0.0 - t107;
    auto t109 = fma(t106, t106, t108);
    half4 t110 = FGlobals.unity_SHC;
    auto t111 = t110.xyz;
    half3 t112 = 0;
    t112.x = t109;
    half3 t113 = half3(t112.x);
    auto t114 = t104.xyz;
    auto t115 = fma(t111, t113, t114);
    auto t116 = t92.xyz;
    half3 t117 = t115 + t116;
    half4 t118 = half4(0, 0, t117[2], 0);
    half4 t119 = half4(0, 0, t118[2], t92[3]);
    auto t120 = fmax(t117, 0.0h);
    auto t121 = int(uint(t33));
    float4 t122 = FGlobals._WorldSpaceLightPos0;
    auto t123 = t122.w;
    bool t124 = t123 < 0.5;
    if (t124) {
        // → BB142
    } else {
        // → BB148
    }
    // BB142:
    auto t125 = t122.xyz;
    half4 t126 = FGlobals._LightColor0;
    auto t127 = t126.xyz;
    auto t128 = float3(t127);
    phi_0 = t128; // phi from BB142
    phi_1 = t125; // phi from BB142
    // BB148:
    float3 t129 = float3(t73.y);
    float4 t130 = FGlobals.hlslcc_mtx4x4_MHYWorldToLightCookie[1];
    auto t131 = t130.xyz;
    float3 t132 = t131 * t129;
    float4 t133 = FGlobals.hlslcc_mtx4x4_MHYWorldToLightCookie[0];
    auto t134 = t133.xyz;
    float3 t135 = float3(t73.x);
    auto t136 = fma(t134, t135, t132);
    float4 t137 = FGlobals.hlslcc_mtx4x4_MHYWorldToLightCookie[2];
    auto t138 = t137.xyz;
    float3 t139 = float3(t73.z);
    auto t140 = fma(t138, t139, t136);
    float4 t141 = FGlobals.hlslcc_mtx4x4_MHYWorldToLightCookie[3];
    auto t142 = t141.xyz;
    float3 t143 = t142 + t140;
    auto t144 = _MHYLightTexture0.sample(sampler_MHYLightTexture0, t143);
    auto t145 = t144.w;
    float3 t146 = float3(0.0, 0.0, 0.0) - t73;
    float3 t147 = float3(t122.w);
    auto t148 = t122.xyz;
    auto t149 = fma(t146, t147, t148);
    auto t150 = dot(t149, t149);
    float4 t151 = FGlobals._mhyMainLightParam;
    auto t152 = t151.x;
    auto t153 = fma(t150, t152, 1.0);
    float t154 = 1.0 / t153;
    auto t155 = fma(t154, 1.04, -0.04);
    auto t156 = clamp(t155, 0.0, 1.0);
    float t157 = float(t145);
    float t158 = t156 * t157;
    float3 t159 = 0;
    t159.x = t158;
    float3 t160 = float3(t159.x);
    half4 t161 = FGlobals._LightColor0;
    auto t162 = t161.xyz;
    auto t163 = float3(t162);
    float3 t164 = t160 * t163;
    auto t165 = half3(t164);
    auto t166 = rsqrt(t150);
    float3 t167 = 0;
    t167.x = t166;
    float3 t168 = float3(t167.x);
    float3 t169 = t168 * t149;
    auto t170 = float3(t165);
    phi_0 = t170; // phi from BB148
    phi_1 = t169; // phi from BB148
    // BB197:
    float4 t171 = FGlobals._ES_MainLightIntensityIncreaseParams;
    auto t172 = t171.z;
    bool t173 = t172 > 1e-05;
    bool t174 = t172 < -1e-05;
    bool t175 = t173 | t174;
    if (t175) {
        // → BB206
    } else {
        phi_2 = phi_0; // phi from BB197
    }
    // BB206:
    auto t176 = t171.x;
    auto t177 = t171.y;
    float t178 = 0.0 - t177;
    auto t179 = fma(t40, t176, t178);
    auto t180 = clamp(t179, 0.0, 1.0);
    auto t181 = t171.w;
    float t182 = 0.0 - t181;
    auto t183 = fma(t180, t181, t182);
    auto t184 = exp2(t183);
    float t185 = t184 * t180;
    float3 t186 = float3(t171.z);
    float3 t187 = t186 * phi_0;
    float3 t188 = 0;
    t188.x = t185;
    float3 t189 = float3(t188.x);
    auto t190 = fma(t189, t187, phi_0);
    phi_2 = t190; // phi from BB206
    // BB222:
    float4 t191 = t74;
    t191.w = 1.0;
    int t192 = FGlobals._MainLightClipPlaneCount;
    bool t193 = t192 == 0;
    if (t193) {
        phi_5 = 1.0; // phi from BB222
    } else {
        // → BB228
    }
    // BB228:
    float4 t194 = FGlobals._mhyWorldOffset;
    auto t195 = t194.xyz;
    phi_3 = 0; // phi from BB228
    phi_4 = 1.0; // phi from BB228
    // BB232:
    ulong t196 = ulong(phi_3);
    float4 t197 = FGlobals._MainLightClipPlaneBaseParamsList[t196];
    auto t198 = t197.xyz;
    auto t199 = dot(t198, t195);
    auto t200 = t197.w;
    float t201 = t199 + t200;
    float4 t202 = 0;
    t202.w = t201;
    float4 t203 = float4(t197[0], t197[1], t197[2], t202[3]);
    auto t204 = dot(t203, t191);
    auto t205 = clamp(t204, 0.0, 1.0);
    auto t206 = fma(t205, -2, 3.0);
    float t207 = t205 * t205;
    float t208 = t207 * t206;
    float t209 = 0.0 - t206;
    auto t210 = fma(t209, t207, 1.0);
    float t211 = FGlobals._MainLightClipPlaneAlphas[t196];
    auto t212 = fma(t211, t210, t208);
    float t213 = float(phi_4);
    float t214 = t212 * t213;
    half t215 = half(t214);
    int t216 = phi_3 + 1;
    bool t217 = t216 < 4;
    bool t218 = t216 < t192;
    bool t219 = t217 & t218;
    if (t219) {
        phi_3 = t216; // phi from BB232
        phi_4 = t215; // phi from BB232
    } else {
        phi_5 = t215; // phi from BB232
    }
    // BB261:
    float t220 = float(phi_5);
    float3 t221 = 0;
    t221.x = t220;
    float3 t222 = float3(t221.x);
    float3 t223 = t222 * phi_2;
    auto t224 = half3(t223);
    int4 t225 = 0;
    t225.x = t121;
    int4 t226 = int4(t225.x);
    bool4 t227 = t226 == int4(13, 8, 14, 6);
    uchar4 t228 = uchar4(t227);
    int3 t229 = 0;
    t229.x = t121;
    int3 t230 = int3(t229.x);
    bool3 t231 = t230 == int3(16, 19, 18);
    auto t232 = int3(uint3(t231));
    int3 t233 = 0 - t232;
    auto t234 = t233.y;
    auto t235 = t233.x;
    int t236 = t234 | t235;
    float t237 = float(t53);
    float4 t238 = t23;
    t238.y = t237;
    bool t239 = t236 == 0;
    if (t239) {
        // → BB286
    } else {
        // → BB283
    }
    // BB283:
    auto t240 = t238.xy;
    auto t241 = half2(t240);
    phi_6 = t241; // phi from BB283
    // BB286:
    auto t242 = t238.yx;
    auto t243 = half2(t242);
    phi_6 = t243; // phi from BB286
    // BB289:
    half4 t244 = half4(phi_6[0], phi_6[1], 0, 0);
    half4 t245 = half4(t244[0], t244[1], t119[2], t119[3]);
    float4 t246 = FGlobals._CameraDepthTexture_TexelSize;
    auto t247 = t246.zw;
    float2 t248 = t20 * float2(0.5, 0.5);
    float2 t249 = t248 * t247;
    auto t250 = floor(t249);
    auto t251 = t246.xy;
    float2 t252 = t250 * t251;
    float2 t253 = t252 * float2(2.0, 2.0);
    auto t254 = t252.xyxy;
    float4 t255 = FGlobals._BlurKernel;
    auto t256 = t255.xyyz;
    auto t257 = fma(t254, float4(2.0, 2.0, 2.0, 2.0), t256);
    auto t258 = t257.zw;
    auto t259 = t255.xy;
    float2 t260 = t258 + t259;
    auto t261 = _AOHalfTexture.sample(sampler_AOHalfTexture, t253);
    half3 t262 = half3(0, t261[2], t261[3]);
    auto t263 = t257.xy;
    auto t264 = _AOHalfTexture.sample(sampler_AOHalfTexture, t263);
    half3 t265 = half3(0, t264[2], t264[3]);
    auto t266 = _AOHalfTexture.sample(sampler_AOHalfTexture, t258);
    half3 t267 = half3(0, t266[2], t266[3]);
    auto t268 = _AOHalfTexture.sample(sampler_AOHalfTexture, t260);
    auto t269 = t268.zwy;
    auto t270 = float3(t269);
    float4 t271 = float4(t270[0], t270[1], t270[2], 0);
    float4 t272 = float4(t257[0], t271[0], t271[1], t271[2]);
    auto t273 = t262.yz;
    auto t274 = dot(t273, half2(1.0, 0.00390625));
    float t275 = float(t274);
    float t276 = t275 * 1.00002;
    float4 t277 = 0;
    t277.x = t276;
    auto t278 = t265.yz;
    auto t279 = dot(t278, half2(1.0, 0.00390625));
    float t280 = float(t279);
    float t281 = t280 * 1.00002;
    float4 t282 = t277;
    t282.y = t281;
    auto t283 = t267.yz;
    auto t284 = dot(t283, half2(1.0, 0.00390625));
    float t285 = float(t284);
    float t286 = t285 * 1.00002;
    float4 t287 = t282;
    t287.z = t286;
    auto t288 = t272.yz;
    auto t289 = dot(t288, float2(1.0, 0.00390625));
    half t290 = half(t289);
    float t291 = float(t290);
    float t292 = t291 * 1.00002;
    float4 t293 = t287;
    t293.w = t292;
    float4 t294 = 0;
    t294.x = t40;
    float4 t295 = float4(t294.x);
    float4 t296 = t293 / t295;
    float4 t297 = t296 + float4(-1, -1, -1, -1);
    float4 t298 = float4(0, 0, 0, 0.0) - t255;
    float4 t299 = float4(t298.w);
    auto t300 = abs(t297);
    auto t301 = fma(t299, t300, float4(1.0, 1.0, 1.0, 1.0));
    auto t302 = clamp(t301, 0, float4(1.0, 1.0, 1.0, 1.0));
    auto t303 = dot(t302, float4(1.0, 1.0, 1.0, 1.0));
    half t304 = half(t303);
    auto t305 = fmax(t304, 0.000100017h);
    auto t306 = t261.y;
    float t307 = float(t306);
    float4 t308 = t272;
    t308.x = t307;
    auto t309 = t264.y;
    float t310 = float(t309);
    float4 t311 = t308;
    t311.y = t310;
    auto t312 = t266.y;
    float t313 = float(t312);
    float4 t314 = t311;
    t314.z = t313;
    auto t315 = dot(t302, t314);
    half t316 = half(t315);
    half t317 = t316 / t305;
    auto t318 = clamp(t317, 0.0h, 1.0h);
    bool t319 = t305 >= 0.0100021;
    float t320 = t319 ? 1.0 : 0.0;
    half t321 = t318 - t306;
    float t322 = float(t321);
    auto t323 = fma(t320, t322, t307);
    auto t324 = t83.xyz;
    auto t325 = float3(t324);
    auto t326 = dot(t325, phi_1);
    half t327 = half(t326);
    auto t328 = t228.w;
    bool t329 = t328 != 0;
    auto t330 = t25.xy;
    half2 t331 = t329 ? half2(0.0400085, 0.0400085) : t330;
    half4 t332 = half4(t331[0], t331[1], 0, 0);
    half4 t333 = t332;
    t333.z = 0.0;
    auto t334 = t228.x;
    uint t335 = uint(t334);
    int t336 = 0 - t335;
    int t337 = t236 | t336;
    half t338 = FGlobals._SpecialElementViewID;
    bool t339 = t338 > 0.799805;
    bool t340 = t338 != 2.0;
    bool t341 = t339 & t340;
    half t342 = FGlobals._ShamanViewOn;
    bool t343 = t342 == 1.0;
    bool t344 = t341 | t343;
    auto t345 = t333.xy;
    auto t346 = float2(t345);
    float3 t347 = float3(t346[0], t346[1], 0);
    auto t348 = t25.z;
    float t349 = float(t348);
    float3 t350 = t347;
    t350.z = t349;
    auto t351 = dot(t350, float3(0.2125, 0.7154, 0.0721));
    float3 t352 = 0;
    t352.x = t351;
    float3 t353 = float3(t352.x);
    half4 t354 = FGlobals._ElementViewSceneBackgroundColor;
    auto t355 = t354.xyz;
    auto t356 = float3(t355);
    float3 t357 = t356 * t350;
    auto t358 = t245.yx;
    half2 t359 = t358 * half2(20, 5);
    auto t360 = phi_6.y;
    auto t361 = t359.x;
    if (t344) {
        // → BB414
    } else {
        phi_7 = 0; // phi from BB289
    }
    // BB414:
    half3 t362 = half3(t354.w);
    auto t363 = float3(t362);
    float3 t364 = float3(0.0, 0.0, 0.0) - t357;
    auto t365 = fma(t353, t356, t364);
    auto t366 = fma(t363, t365, t357);
    float3 t367 = t353 * t356;
    float3 t368 = t343 ? t366 : t367;
    auto t369 = half3(t368);
    phi_7 = t369; // phi from BB414
    // BB423:
    int t370 = t344 ? -1 : t235;
    bool t371 = t370 == 0;
    half t372 = t361 * t360;
    half t373 = t371 ? 0.0 : t372;
    bool t374 = t235 != 0;
    if (t374) {
        // → BB430
    } else {
        phi_8 = phi_7; // phi from BB423
    }
    // BB430:
    auto t375 = half3(t350);
    phi_8 = t375; // phi from BB430
    // BB432:
    half4 t376 = half4(0, phi_6[1], 0, 0);
    bool t377 = t370 == -1;
    half t378 = t377 ? t373 : 0.0;
    bool t379 = t337 != 0;
    half3 t380 = t379 ? phi_8 : 0;
    half4 t381 = t245;
    t381.w = 0.0400085;
    half4 t382 = t381;
    t382.z = t378;
    half4 t383 = half4(t333[0], t376[1], t333[2], 0);
    auto t384 = t382.wxz;
    auto t385 = t383.xyz;
    half3 t386 = t379 ? t384 : t385;
    auto t387 = t386.x;
    bool t388 = t387 < 0.503906;
    half t389 = t387 * 255;
    float t390 = float(t389);
    auto t391 = int(uint(t390));
    int t392 = t391 & 127;
    auto t393 = float(uint(t392));
    float t394 = t393 * 0.00787402;
    if (t388) {
        // → BB453
    } else {
        // → BB467
    }
    // BB453:
    auto t395 = fma(t82, 0.7, 0.3);
    float t396 = t395 - t82;
    auto t397 = fma(t394, t396, t82);
    float3 t398 = t350;
    t398.x = t397;
    float t399 = float(t327);
    auto t400 = fma(t393, 0.00787402, t399);
    auto t401 = fma(t393, 0.00787402, 1.0);
    float t402 = t401 * t401;
    float t403 = t400 / t402;
    float3 t404 = t398;
    t404.y = t403;
    auto t405 = t404.xy;
    auto t406 = half2(t405);
    half3 t407 = half3(t406[0], t406[1], 0);
    phi_9 = t407; // phi from BB453
    phi_10 = t404; // phi from BB453
    // BB467:
    half3 t408 = 0;
    t408.x = t81;
    half3 t409 = t408;
    t409.y = t327;
    phi_9 = t409; // phi from BB467
    phi_10 = t350; // phi from BB467
    // BB470:
    float3 t410 = 0;
    t410.x = t82;
    float3 t411 = float3(t410.x);
    auto t412 = float3(t224);
    float3 t413 = t412 * t411;
    auto t414 = half3(t413);
    auto t415 = dot(t414, half3(0.0396729, 0.458008, 0.00609589));
    auto t416 = t359.y;
    half t417 = t415 * t416;
    float t418 = float(t417);
    float t419 = t394 * t418;
    half t420 = half(t419);
    half t421 = t344 ? t420 : 0.0;
    auto t422 = t228.z;
    bool t423 = t422 != 0;
    half3 t424 = t423 ? half3(1.0, 1.0, 1.0) : t380;
    uint t425 = uint(t422);
    int t426 = 0 - t425;
    uint t427 = uint(t328);
    int t428 = 0 - t427;
    int t429 = t428 | t426;
    int t430 = t429 | t337;
    bool t431 = t430 == 0;
    half2 t432 = t431 ? t330 : half2(0.0400085, 0.0400085);
    auto t433 = phi_9.x;
    half t434 = t423 ? t433 : t81;
    half4 t435 = 0;
    t435.x = t434;
    auto t436 = t386.z;
    half t437 = t423 ? t421 : t436;
    auto t438 = phi_9.y;
    half t439 = t423 ? t438 : t327;
    auto t440 = clamp(t439, 0.0h, 1.0h);
    auto t441 = t386.y;
    int2 t442 = int2(t233.z);
    int2 t443 = 0;
    t443.x = t430;
    int2 t444 = int2(t443.x);
    int2 t445 = t444 | t442;
    auto t446 = t445.x;
    bool t447 = t446 == 0;
    auto t448 = t25.x;
    half t449 = t447 ? t448 : 0.0400085;
    half4 t450 = t104;
    t450.x = t449;
    auto t451 = t445.y;
    bool t452 = t451 == 0;
    auto t453 = t25.y;
    half t454 = t452 ? t453 : 0.0400085;
    half4 t455 = t450;
    t455.y = t454;
    auto t456 = t233.z;
    bool t457 = t456 != 0;
    auto t458 = phi_10.z;
    half t459 = half(t458);
    half t460 = t457 ? 0.0400085 : t459;
    half4 t461 = t455;
    t461.z = t460;
    auto t462 = t424.xy;
    half2 t463 = t457 ? t432 : t462;
    half3 t464 = half3(t463[0], t463[1], 0);
    auto t465 = t424.z;
    half t466 = t457 ? t459 : t465;
    half3 t467 = t464;
    t467.z = t466;
    int t468 = t337 | t456;
    bool t469 = t468 == 0;
    auto t470 = phi_6.x;
    half t471 = t469 ? t360 : t470;
    half t472 = t441 * t441;
    half t473 = t472 * 20;
    half t474 = t457 ? t473 : t437;
    half t475 = FGlobals._ElementViewEleDrawOn;
    bool t476 = t475 != 0.0;
    half t477 = t460 * 255;
    half3 t478 = 0;
    t478.y = t477;
    auto t479 = t461.xyx;
    auto t480 = dot(t479, half3(0.0396729, 0.458008, 0.00609589));
    half3 t481 = t478;
    t481.x = t480;
    half4 t482 = t461;
    t482.w = 0.0;
    auto t483 = t481.xxxy;
    half4 t484 = t476 ? t483 : t482;
    half t485 = 1.0 - t471;
    float3 t486 = float3(0.0, 0.0, 0.0) - stageIn.TEXCOORD1;
    auto t487 = fma(t486, t78, phi_1);
    auto t488 = dot(t487, t487);
    auto t489 = rsqrt(t488);
    float3 t490 = 0;
    t490.x = t489;
    float3 t491 = float3(t490.x);
    float3 t492 = t491 * t487;
    auto t493 = dot(t325, t492);
    auto t494 = clamp(t493, 0.0, 1.0);
    auto t495 = dot(phi_1, t492);
    auto t496 = clamp(t495, 0.0, 1.0);
    half t497 = t485 * t485;
    half t498 = t497 * t497;
    float t499 = float(t498);
    float t500 = 0.0 - t494;
    auto t501 = fma(t494, t499, t500);
    auto t502 = fma(t501, t494, 1.0);
    float t503 = t502 * t502;
    auto t504 = fmax(t503, 0.0001);
    float t505 = t499 / t504;
    float t506 = t505 * 0.31831;
    auto t507 = fmin(t506, 12);
    half t508 = 0.0 - t497;
    auto t509 = fma(t508, t497, 1.0h);
    half t510 = t509 * 2.0;
    half4 t511 = 0;
    t511.x = t510;
    auto t512 = t484.xyz;
    half3 t513 = half3(1.0, 1.0, 1.0) - t512;
    float t514 = 1.0 - t496;
    float t515 = t514 * t514;
    float t516 = t515 * t515;
    float t517 = t516 * t514;
    float3 t518 = 0;
    t518.x = t517;
    float3 t519 = float3(t518.x);
    auto t520 = float3(t513);
    float3 t521 = t519 * t520;
    half3 t522 = half3(t511.x);
    auto t523 = float3(t522);
    auto t524 = float3(t512);
    auto t525 = fma(t521, t523, t524);
    float3 t526 = 0;
    t526.x = t507;
    float3 t527 = float3(t526.x);
    float3 t528 = t525 * t527;
    auto t529 = t24.xyz;
    half3 t530 = 0;
    t530.x = t440;
    half3 t531 = half3(t530.x);
    half3 t532 = t531 * t224;
    half3 t533 = half3(t435.x);
    half3 t534 = t532 * t533;
    half4 t535 = FGlobals._SandGliter_TillPowerGamma;
    half3 t536 = half3(t535.z);
    half3 t537 = t536 * t120;
    half3 t538 = half3(t535.y);
    auto t539 = fma(t534, t538, t537);
    auto t540 = fma(t529, t539, t539);
    half3 t541 = t329 ? t540 : t467;
    if (t329) {
        // → BB607
    } else {
        // → BB615
    }
    // BB607:
    half3 t542 = half3(t382.x);
    auto t543 = fma(t529, half3(0.950195, 0.950195, 0.950195), half3(0.0499878, 0.0499878, 0.0499878));
    half3 t544 = t543 + half3(-1.0, -1.0, -1.0);
    auto t545 = fma(t542, t544, half3(1.0, 1.0, 1.0));
    auto t546 = float3(t545);
    float3 t547 = t546 * t528;
    auto t548 = half3(t547);
    phi_11 = t548; // phi from BB607
    // BB615:
    auto t549 = half3(t528);
    phi_11 = t549; // phi from BB615
    // BB617:
    half3 t550 = t532 * phi_11;
    half t551 = FGlobals._StaticObjectRimWidthScaleReverse;
    half t552 = 0.0 - t551;
    auto t553 = fma(t552, 2.0h, 2.0h);
    half2 t554 = half2(t83.y);
    auto t555 = float2(t554);
    float4 t556 = FGlobals.hlslcc_mtx4x4unity_WorldToCamera[1];
    auto t557 = t556.xy;
    float2 t558 = t557 * t555;
    float4 t559 = FGlobals.hlslcc_mtx4x4unity_WorldToCamera[0];
    auto t560 = t559.xy;
    half2 t561 = half2(t83.x);
    auto t562 = float2(t561);
    auto t563 = fma(t560, t562, t558);
    float4 t564 = FGlobals.hlslcc_mtx4x4unity_WorldToCamera[2];
    auto t565 = t564.xy;
    half2 t566 = half2(t83.z);
    auto t567 = float2(t566);
    auto t568 = fma(t565, t567, t563);
    float3 t569 = float3(t568[0], t568[1], 0);
    float3 t570 = t569;
    t570.z = 0.001;
    auto t571 = dot(t570, t570);
    half t572 = half(t571);
    auto t573 = rsqrt(t572);
    half3 t574 = 0;
    t574.x = t573;
    auto t575 = t570.xy;
    half2 t576 = half2(t574.x);
    auto t577 = float2(t576);
    float2 t578 = t575 * t577;
    auto t579 = half2(t578);
    half2 t580 = 0;
    t580.x = t553;
    half2 t581 = half2(t580.x);
    half2 t582 = t579 * t581;
    auto t583 = float2(t582);
    auto t584 = fma(t583, float2(0.001, 0.001), t20);
    auto t585 = _CameraDepthTexture.sample(sampler_CameraDepthTexture, t584);
    auto t586 = t585.x;
    auto t587 = fma(t37, t586, t38);
    float t588 = 1.0 / t587;
    float t589 = t588 - t40;
    half t590 = half(t589);
    auto t591 = fmax(t590, 0.0010004h);
    auto t592 = log2(t591);
    half t593 = t592 * 0.0400085;
    auto t594 = exp2(t593);
    half t595 = t594 + -0.799805;
    half t596 = t595 * 10;
    auto t597 = clamp(t596, 0.0h, 1.0h);
    auto t598 = fma(t597, -2.0h, 3.0h);
    half t599 = t597 * t597;
    half t600 = t599 * t598;
    float t601 = 2.0 - t40;
    half t602 = half(t601);
    float t603 = float(t602);
    auto t604 = fma(t603, 0.3, t40);
    half t605 = half(t604);
    auto t606 = fmin(t605, 1.0h);
    half t607 = t600 * t606;
    half3 t608 = 0;
    t608.x = t607;
    float3 t609 = float3(0.0, 0.0, 0.0) - t79;
    auto t610 = dot(t609, t325);
    half t611 = half(t610);
    half t612 = 1.0 - t611;
    auto t613 = clamp(t612, 0.0h, 1.0h);
    auto t614 = fmax(t613, 0.0100021h);
    half t615 = t614 * t614;
    half t616 = t615 * t615;
    half t617 = t616 * t614;
    half3 t618 = FGlobals._ES_SceneFrontRimColor;
    half3 t619 = 0;
    t619.x = t617;
    half3 t620 = half3(t619.x);
    half3 t621 = t529 * half3(5, 5, 5);
    auto t622 = clamp(t621, 0.0h, half3(1.0, 1.0, 1.0));
    half3 t623 = t608 * t530;
    half3 t624 = half3(t623.x);
    half3 t625 = t624 * t618;
    half3 t626 = t625 * t622;
    half3 t627 = t626 * t620;
    auto t628 = fma(t550, t533, t627);
    auto t629 = t228.y;
    bool t630 = t629 == 0;
    if (t630) {
        phi_12 = t323; // phi from BB617
    } else {
        // → BB705
    }
    // BB705:
    half t631 = 0.0 - t470;
    auto t632 = fma(t631, 0.700195h, 1.0h);
    float t633 = float(t632);
    auto t634 = fmin(t323, t633);
    phi_12 = t634; // phi from BB705
    // BB710:
    half t635 = half(phi_12);
    half4 t636 = 0;
    t636.x = t635;
    auto t637 = dot(t120, half3(0.212646, 0.715332, 0.0722046));
    auto t638 = fmax(t637, 1.0h);
    half3 t639 = t120 * half3(0.785156, 0.785156, 0.785156);
    half3 t640 = 0;
    t640.x = t638;
    half3 t641 = half3(t640.x);
    half3 t642 = t639 / t641;
    half3 t643 = half3(1.0, 1.0, 1.0) - t642;
    half3 t644 = half3(t636.x);
    auto t645 = fma(t644, t643, t642);
    float t646 = t82 + 0.0001;
    half t647 = half(t646);
    auto t648 = log2(t647);
    half t649 = t648 * 0.199951;
    auto t650 = exp2(t649);
    half t651 = t650 * t440;
    auto t652 = fma(t651, 0.5h, 0.5h);
    half2 t653 = half2(0, 0.0);
    t653.x = t652;
    auto t654 = float2(t653);
    auto t655 = _DeferredToonRampTex.sample(sampler_AOHalfTexture, t654);
    auto t656 = t655.x;
    float t657 = float(t656);
    float3 t658 = 0;
    t658.x = t657;
    float3 t659 = float3(t658.x);
    half4 t660 = FGlobals._LightColor0;
    auto t661 = t660.xyz;
    auto t662 = float3(t661);
    float3 t663 = t659 * t662;
    auto t664 = half3(t663);
    auto t665 = fma(t120, t645, t664);
    if (t374) {
        // → BB744
    } else {
        phi_13 = t628; // phi from BB710
    }
    // BB744:
    half3 t666 = t541 + half3(-1.0, -1.0, -1.0);
    auto t667 = fma(t666, half3(0.5, 0.5, 0.5), half3(1.0, 1.0, 1.0));
    half3 t668 = t667 * t628;
    auto t669 = float3(t668);
    float3 t670 = t669 * float3(0.6, 0.6, 0.6);
    auto t671 = half3(t670);
    phi_13 = t671; // phi from BB744
    // BB751:
    half3 t672 = t645 * t541;
    bool t673 = t234 == 0;
    half3 t674 = t673 ? t541 : t672;
    half3 t675 = 0;
    t675.x = t474;
    half3 t676 = half3(t675.x);
    if (t374) {
        // → BB758
    } else {
        // → BB761
    }
    // BB758:
    half3 t677 = t674 * t676;
    auto t678 = float3(t677);
    phi_14 = t678; // phi from BB758
    // BB761:
    auto t679 = fma(t665, t529, phi_13);
    auto t680 = fma(t674, t676, t679);
    auto t681 = float3(t680);
    phi_14 = t681; // phi from BB761
    // BB765:
    auto t682 = float(uint(t121));
    auto t683 = fmax(phi_14, float3(0.0001, 0.0001, 0.0001));
    auto t684 = half3(t683);
    auto t685 = min(t51, 3);
    int t686 = t685 * 3;
    auto t687 = dot(t684, half3(0.212646, 0.715332, 0.0722046));
    half3 t688 = 0;
    t688.x = t687;
    half3 t689 = half3(0.0, 0, 0) - t688;
    half3 t690 = half3(t689.x);
    half3 t691 = t690 + t684;
    long t692 = long(t686);
    float4 t693 = FGlobals._ColorGradingProfileArray[t692];
    auto t694 = t693.xyz;
    auto t695 = float3(t691);
    float t696 = float(t687);
    float3 t697 = 0;
    t697.x = t696;
    float3 t698 = float3(t697.x);
    auto t699 = fma(t694, t695, t698);
    auto t700 = fmax(t699, 0);
    auto t701 = log2(t700);
    auto t702 = t701.x;
    auto t703 = t693.w;
    float t704 = t702 * t703;
    float3 t705 = 0;
    t705.x = t704;
    auto t706 = t701.y;
    int t707 = t686 + 1;
    long t708 = long(t707);
    float4 t709 = FGlobals._ColorGradingProfileArray[t708];
    auto t710 = t709.w;
    float t711 = t710 * t706;
    float3 t712 = t705;
    t712.y = t711;
    auto t713 = t701.z;
    int t714 = t686 + 2;
    long t715 = long(t714);
    float4 t716 = FGlobals._ColorGradingProfileArray[t715];
    auto t717 = t716.w;
    float t718 = t717 * t713;
    float3 t719 = t712;
    t719.z = t718;
    auto t720 = exp2(t719);
    auto t721 = t709.xyz;
    auto t722 = t716.xyz;
    auto t723 = fma(t720, t721, t722);
    auto t724 = float3(t684);
    float3 t725 = t723 - t724;
    float3 t726 = float3(t69.x);
    auto t727 = fma(t726, t725, t724);
    auto t728 = t484.w;
    half t729 = t728 + -1.0;
    bool t730 = t729 > 8.5;
    bool t731 = t729 <= 9.5;
    bool t732 = t731 & t730;
    if (t732) {
        // → BB1367
    } else {
        // → BB821
    }
    // BB821:
    auto t733 = t559.z;
    float3 t734 = 0;
    t734.x = t733;
    auto t735 = t556.z;
    float3 t736 = t734;
    t736.y = t735;
    auto t737 = t564.z;
    float3 t738 = t736;
    t738.z = t737;
    auto t739 = dot(stageIn.TEXCOORD1, t738);
    float4 t740 = FGlobals._ProjectionParams;
    auto t741 = t740.z;
    float t742 = t741 / t739;
    float3 t743 = 0;
    t743.x = t742;
    float3 t744 = float3(t743.x);
    float3 t745 = t744 * stageIn.TEXCOORD1;
    float3 t746 = t745 * t71;
    float4 t747 = float4(t746[0], t746[1], t746[2], 0);
    float4 t748 = float4(t747[0], t747[1], t747[2], t191[3]);
    auto t749 = dot(t746, t746);
    auto t750 = sqrt(t749);
    float4 t751 = FGlobals._ElementViewParamsFloat1;
    auto t752 = t751.y;
    bool t753 = t752 < t750;
    if (t753) {
        // → BB1363
    } else {
        // → BB845
    }
    // BB845:
    half3 t754 = 0;
    t754.x = t338;
    half3 t755 = half3(t754.x);
    bool3 t756 = t755 == half3(0.0, 2.0, 3);
    uchar3 t757 = uchar3(t756);
    auto t758 = t757.y;
    auto t759 = t757.x;
    uint8_t t760 = t759 | t758;
    auto t761 = t757.z;
    bool t762 = t761 == 0;
    uint8_t t763 = t760 | t761;
    bool t764 = t763 == 0;
    if (t764) {
        // → BB1306
    } else {
        // → BB857
    }
    // BB857:
    auto t765 = fma(t745, t71, t72);
    float3 t766 = t727 * t356;
    auto t767 = half3(t766);
    bool t768 = t342 != 0.0;
    if (t768) {
        // → BB862
    } else {
        phi_15 = t767; // phi from BB857
    }
    // BB862:
    half3 t769 = half3(t354.w);
    auto t770 = float3(t769);
    float3 t771 = float3(0.0, 0.0, 0.0) - t727;
    auto t772 = dot(t767, half3(0.212524, 0.715332, 0.0720825));
    float t773 = float(t772);
    float3 t774 = 0;
    t774.x = t773;
    float3 t775 = float3(t774.x);
    auto t776 = fma(t771, t356, t775);
    auto t777 = float3(t767);
    auto t778 = fma(t770, t776, t777);
    float3 t779 = t778 * t356;
    auto t780 = half3(t779);
    phi_15 = t780; // phi from BB862
    // BB875:
    bool t781 = t729 > -0.5;
    half4 t782 = FGlobals._ElementViewParamsHalf2;
    auto t783 = t782.y;
    half t784 = t783 + -0.5;
    bool t785 = t729 < t784;
    bool t786 = t781 & t785;
    if (t786) {
        // → BB884
    } else {
        // → BB954
    }
    // BB884:
    half t787 = t728 + -0.5;
    float t788 = float(t787);
    auto t789 = int(uint(t788));
    float2 t790 = float2(t765.y);
    auto t791 = t765.xz;
    auto t792 = fma(t790, float2(0.5, 0.5), t791);
    float4 t793 = FGlobals._Time;
    float2 t794 = float2(t793.y);
    float4 t795 = FGlobals._ElementViewParamsFloat2;
    float2 t796 = float2(t795.x);
    auto t797 = fma(t794, t796, t792);
    float2 t798 = float2(t795.z);
    float2 t799 = t797 * t798;
    auto t800 = _ElementViewElePatternTex.sample(sampler_ElementViewElePatternTex, t799);
    auto t801 = t800.x;
    auto t802 = t28.z;
    float t803 = float(t802);
    auto t804 = t79.x;
    float t805 = t804 * t803;
    auto t806 = t79.z;
    float t807 = 0.0 - t806;
    float t808 = float(t106);
    auto t809 = fma(t807, t808, t805);
    bool t810 = t809 > 0.0;
    float t811 = t810 ? -0.0088 : 0.0088;
    auto t812 = fma(t40, t741, 3.0);
    float t813 = t811 / t812;
    auto t814 = stageIn.TEXCOORD0.x;
    float t815 = t813 + t814;
    float2 t816 = 0;
    t816.x = t815;
    auto t817 = stageIn.TEXCOORD0.y;
    float2 t818 = t816;
    t818.y = t817;
    auto t819 = _CameraDepthTexture.sample(sampler_CameraDepthTexture, t818);
    auto t820 = t819.x;
    auto t821 = fma(t37, t820, t38);
    float t822 = 1.0 / t821;
    float t823 = t822 - t40;
    auto t824 = fmax(t823, 1e-06);
    auto t825 = log2(t824);
    half t826 = half(t825);
    half t827 = t826 * 0.0149994;
    auto t828 = exp2(t827);
    half t829 = t828 + -0.819824;
    half t830 = t829 * 12.5;
    auto t831 = clamp(t830, 0.0h, 1.0h);
    auto t832 = fma(t831, -2.0h, 3.0h);
    half t833 = t831 * t831;
    half t834 = t833 * t832;
    half4 t835 = FGlobals._ElementViewParamsHalf1;
    auto t836 = t835.w;
    half t837 = t834 * t836;
    auto t838 = t835.z;
    auto t839 = fma(t801, t838, t837);
    auto t840 = t835.y;
    half t841 = t839 + t840;
    half4 t842 = t83;
    t842.x = t841;
    half3 t843 = half3(t842.x);
    long t844 = long(t789);
    half4 t845 = FGlobals._ElementViewEleColors[t844];
    auto t846 = t845.xyz;
    half3 t847 = t843 * t846;
    half3 t848 = half3(t835.y);
    auto t849 = fma(t847, t848, phi_15);
    half4 t850 = half4(t849[0], t849[1], t849[2], 0);
    half4 t851 = half4(t850[0], t842[1], t850[1], t850[2]);
    phi_18 = t851; // phi from BB884
    // BB954:
    if (t768) {
        // → BB955
    } else {
        // → BB1193
    }
    // BB955:
    auto t852 = t765.xz;
    float4 t853 = FGlobals._ElementViewParamsFloat2;
    float2 t854 = float2(t853.w);
    float2 t855 = t854 * t852;
    auto t856 = _ElementViewSceneWaveTex.sample(sampler_ElementViewSceneWaveTex, t855);
    auto t857 = t856.x;
    float4 t858 = FGlobals._ShamanSymbolMaskUV;
    auto t859 = t858.xy;
    auto t860 = t858.zw;
    auto t861 = fma(t855, t859, t860);
    auto t862 = _ElementViewSceneWaveTex.sample(sampler_ElementViewSceneWaveTex, t861);
    auto t863 = t862.z;
    half4 t864 = FGlobals._ElementViewParamsHalf1;
    auto t865 = t864.x;
    half t866 = t865 * t857;
    auto t867 = t782.z;
    float t868 = float(t867);
    float t869 = float(t866);
    auto t870 = fma(t750, t868, t869);
    half t871 = half(t870);
    float4 t872 = FGlobals._Time;
    auto t873 = t872.y;
    float t874 = 0.0 - t873;
    auto t875 = t751.x;
    float t876 = float(t871);
    auto t877 = fma(t874, t875, t876);
    auto t878 = fract(t877);
    float t879 = t878 + -0.5;
    auto t880 = t782.w;
    half t881 = 1.0 / t880;
    auto t882 = abs(t879);
    float t883 = float(t881);
    float t884 = t882 * t883;
    auto t885 = clamp(t884, 0.0, 1.0);
    auto t886 = fma(t885, -2, 3.0);
    float t887 = t885 * t885;
    float t888 = 0.0 - t886;
    auto t889 = fma(t888, t887, 1.0);
    half3 t890 = FGlobals._ShamanViewWaveColorA;
    half3 t891 = FGlobals._ShamanViewWaveColorB;
    half3 t892 = t891 - t890;
    float3 t893 = 0;
    t893.x = t889;
    float3 t894 = float3(t893.x);
    auto t895 = float3(t892);
    auto t896 = float3(t890);
    auto t897 = fma(t894, t895, t896);
    auto t898 = half3(t897);
    half3 t899 = t898 * t898;
    float4 t900 = FGlobals._ElementViewParamsFloat3;
    auto t901 = t900.x;
    float t902 = t873 - t901;
    auto t903 = t751.w;
    float t904 = t902 * t903;
    auto t905 = fract(t904);
    float t906 = t752 * t905;
    float t907 = 0.0 - t906;
    auto t908 = fma(t907, t868, t876);
    half t909 = half(t908);
    half4 t910 = FGlobals._ElementViewParamsHalf3;
    auto t911 = t910.w;
    half t912 = 1.0 / t911;
    auto t913 = abs(t909);
    half t914 = t912 * t913;
    auto t915 = clamp(t914, 0.0h, 1.0h);
    auto t916 = fma(t915, -2.0h, 3.0h);
    half t917 = t915 * t915;
    half t918 = 0.0 - t916;
    auto t919 = fma(t918, t917, 1.0h);
    float t920 = t886 * t887;
    float t921 = 0.0 - t920;
    auto t922 = fract(t921);
    half t923 = half(t922);
    float2 t924 = float2(t853.y);
    float t925 = float(t923);
    float2 t926 = 0;
    t926.x = t925;
    float2 t927 = float2(t926.x);
    auto t928 = fma(t852, t924, t927);
    auto t929 = _ElementViewScenePatternTex.sample(sampler_ElementViewScenePatternTex, t928);
    auto t930 = t929.x;
    float t931 = FGlobals._ShamanViewLength;
    float t932 = FGlobals._ShamanViewOffset;
    auto t933 = fma(t750, t931, t932);
    auto t934 = clamp(t933, 0.0, 1.0);
    float3 t935 = 0;
    t935.x = t934;
    auto t936 = fmax(t105, 0.0h);
    float t937 = float(t936);
    float t938 = t934 * t937;
    float t939 = float(t930);
    auto t940 = fma(t939, t938, 0.0001);
    float t941 = float(t919);
    float t942 = t889 + t941;
    half t943 = half(t942);
    half t944 = t943 + 0.5;
    half t945 = 0.5 / t944;
    auto t946 = log2(t940);
    float t947 = float(t945);
    float t948 = t946 * t947;
    auto t949 = exp2(t948);
    float t950 = FGlobals._ShamanViewSymbolScale;
    float2 t951 = 0;
    t951.x = t950;
    float2 t952 = float2(t951.x);
    float2 t953 = t952 * t852;
    float3 t954 = float3(t953[0], t953[1], 0);
    float3 t955 = t954;
    t955.z = 0.0;
    float3 t956 = 0;
    t956.x = t925;
    float3 t957 = float3(t956.x);
    float t958 = FGlobals._waveSymbolScale;
    float3 t959 = 0;
    t959.x = t958;
    float3 t960 = float3(t959.x);
    auto t961 = fma(t957, t960, t955);
    auto t962 = t961.xy;
    auto t963 = t961.z;
    auto t964 = _ElementViewSceneWaveTex.sample(sampler_ElementViewSceneWaveTex, t962, level(t963));
    auto t965 = t964.y;
    bool t966 = t965 > 0.125;
    float t967 = t966 ? 1.0 : 0.0;
    float3 t968 = 0;
    t968.x = t967;
    auto t969 = t955.xy;
    auto t970 = floor(t969);
    auto t971 = dot(t970, float2(12.9898, 78.233));
    auto t972 = sin(t971);
    float t973 = t972 * 43758.5;
    auto t974 = fract(t973);
    auto t975 = log2(t974);
    float2 t976 = 0;
    t976.x = t975;
    float2 t977 = float2(t976.x);
    float t978 = FGlobals._ShamanViewRandomX;
    float2 t979 = 0;
    t979.x = t978;
    float t980 = FGlobals._ShamanViewRandomY;
    float2 t981 = t979;
    t981.y = t980;
    float2 t982 = t981 * t977;
    auto t983 = exp2(t982);
    auto t984 = t983.y;
    auto t985 = t983.x;
    float t986 = t984 * t985;
    auto t987 = int2(t970);
    int2 t988 = t987 & int2(-2.14748e+09, -2.14748e+09);
    int2 t989 = 0 - t987;
    auto t990 = max(t987, t989);
    int t991 = FGlobals._ShamanViewXpattern;
    int2 t992 = 0;
    t992.x = t991;
    int t993 = FGlobals._ShamanViewYpattern;
    int2 t994 = t992;
    t994.y = t993;
    int2 t995 = 0 - t994;
    auto t996 = max(t994, t995);
    int2 t997 = t990 % t996;
    int2 t998 = 0 - t997;
    auto t999 = t988.x;
    bool t1000 = t999 == 0;
    auto t1001 = t998.x;
    auto t1002 = t997.x;
    int t1003 = t1000 ? t1002 : t1001;
    auto t1004 = t988.y;
    bool t1005 = t1004 == 0;
    auto t1006 = t998.y;
    auto t1007 = t997.y;
    int t1008 = t1005 ? t1007 : t1006;
    bool t1009 = t1003 == 0;
    float t1010 = t1009 ? 0.0 : 1.0;
    bool t1011 = t1008 == 0;
    float t1012 = t1011 ? 0.0 : 1.0;
    float t1013 = t1010 * t986;
    float t1014 = t1013 * t1012;
    bool t1015 = t1014 >= 0.01;
    float t1016 = t1015 ? 1.0 : 0.0;
    float3 t1017 = 0;
    t1017.x = t1016;
    float3 t1018 = float3(t968.x);
    half3 t1019 = FGlobals._ShamanViewDarkenColor;
    auto t1020 = float3(t1019);
    float3 t1021 = t1020 * t1018;
    auto t1022 = half3(t1021);
    float3 t1023 = float3(t1017.x);
    auto t1024 = float3(t1022);
    float t1025 = FGlobals._ShamanSymbolBreathSpeed;
    auto t1026 = fma(t873, t1025, t986);
    auto t1027 = fract(t1026);
    float t1028 = t1027 + -0.5;
    float3 t1029 = 0;
    t1029.x = t1028;
    float3 t1030 = float3(t1029.x);
    auto t1031 = abs(t1030);
    float t1032 = float(t863);
    float3 t1033 = 0;
    t1033.x = t1032;
    float3 t1034 = t935 * t1033;
    float3 t1035 = float3(t1034.x);
    float3 t1036 = t1035 * t1024;
    float3 t1037 = t1036 * t1031;
    float3 t1038 = t1037 * t1023;
    auto t1039 = dot(phi_15, half3(0.0396729, 0.458008, 0.00609589));
    auto t1040 = fma(t1039, 10.0h, 1.0h);
    float3 t1041 = 0;
    t1041.x = t949;
    float3 t1042 = float3(t1041.x);
    half3 t1043 = FGlobals._ElementViewSceneLightColor;
    auto t1044 = float3(t1043);
    float3 t1045 = t1044 * t1042;
    auto t1046 = half3(t1045);
    half3 t1047 = half3(t910.y);
    half3 t1048 = t899 * t1047;
    auto t1049 = float3(t1048);
    float3 t1050 = t1049 * t894;
    auto t1051 = half3(t1050);
    half3 t1052 = half3(t782.x);
    auto t1053 = fma(t1046, t1052, t1051);
    half3 t1054 = 0;
    t1054.x = t919;
    half3 t1055 = half3(t1054.x);
    half3 t1056 = t1043 * t1055;
    half3 t1057 = half3(t910.z);
    auto t1058 = fma(t1056, t1057, t1053);
    auto t1059 = float3(t1058);
    auto t1060 = fma(t1038, float3(2.0, 2.0, 2.0), t1059);
    auto t1061 = half3(t1060);
    half3 t1062 = 0;
    t1062.x = t1040;
    half3 t1063 = half3(t1062.x);
    half3 t1064 = t1061 * t1063;
    half3 t1065 = 0;
    t1065.x = t936;
    half3 t1066 = half3(t1065.x);
    auto t1067 = fma(t1064, t1066, phi_15);
    half4 t1068 = half4(t1067[0], t1067[1], t1067[2], 0);
    half4 t1069 = half4(t1068[0], t83[1], t1068[1], t1068[2]);
    phi_18 = t1069; // phi from BB955
    // BB1193:
    auto t1070 = t738.xz;
    float2 t1071 = t1070 + float2(0.001, 0.001);
    auto t1072 = dot(t1071, t1071);
    auto t1073 = rsqrt(t1072);
    float2 t1074 = 0;
    t1074.x = t1073;
    float2 t1075 = float2(t1074.x);
    float2 t1076 = t1075 * t1071;
    float3 t1077 = float3(t1076[0], t1076[1], 0);
    auto t1078 = t1076.y;
    float t1079 = 0.0 - t1078;
    float3 t1080 = t1077;
    t1080.z = t1079;
    auto t1081 = t748.zx;
    auto t1082 = t1080.xz;
    auto t1083 = dot(t1081, t1082);
    float2 t1084 = 0;
    t1084.x = t1083;
    auto t1085 = t748.xz;
    auto t1086 = t1080.xy;
    auto t1087 = dot(t1085, t1086);
    float2 t1088 = t1084;
    t1088.y = t1087;
    float4 t1089 = FGlobals._ElementViewParamsFloat2;
    float2 t1090 = float2(t1089.y);
    float2 t1091 = t1090 * t1088;
    auto t1092 = _ElementViewScenePatternTex.sample(sampler_ElementViewScenePatternTex, t1091);
    auto t1093 = t1092.x;
    auto t1094 = fmax(t105, 0.0h);
    auto t1095 = t765.xz;
    float2 t1096 = float2(t1089.w);
    float2 t1097 = t1096 * t1095;
    auto t1098 = _ElementViewSceneWaveTex.sample(sampler_ElementViewSceneWaveTex, t1097);
    auto t1099 = t1098.x;
    half4 t1100 = FGlobals._ElementViewParamsHalf1;
    auto t1101 = t1100.x;
    half t1102 = t1101 * t1099;
    auto t1103 = t782.z;
    float t1104 = float(t1103);
    float t1105 = float(t1102);
    auto t1106 = fma(t750, t1104, t1105);
    half t1107 = half(t1106);
    float4 t1108 = FGlobals._Time;
    auto t1109 = t1108.y;
    float t1110 = 0.0 - t1109;
    auto t1111 = t751.x;
    float t1112 = float(t1107);
    auto t1113 = fma(t1110, t1111, t1112);
    auto t1114 = fract(t1113);
    float t1115 = t1114 + -0.5;
    auto t1116 = t782.w;
    half t1117 = 1.0 / t1116;
    auto t1118 = abs(t1115);
    float t1119 = float(t1117);
    float t1120 = t1118 * t1119;
    auto t1121 = clamp(t1120, 0.0, 1.0);
    auto t1122 = fma(t1121, -2, 3.0);
    float t1123 = t1121 * t1121;
    float t1124 = 0.0 - t1122;
    auto t1125 = fma(t1124, t1123, 1.0);
    float4 t1126 = FGlobals._ElementViewParamsFloat3;
    auto t1127 = t1126.x;
    float t1128 = t1109 - t1127;
    auto t1129 = t751.w;
    float t1130 = t1128 * t1129;
    auto t1131 = fract(t1130);
    float t1132 = t752 * t1131;
    float t1133 = 0.0 - t1132;
    auto t1134 = fma(t1133, t1104, t1112);
    half t1135 = half(t1134);
    half4 t1136 = FGlobals._ElementViewParamsHalf3;
    auto t1137 = t1136.w;
    half t1138 = 1.0 / t1137;
    auto t1139 = abs(t1135);
    half t1140 = t1138 * t1139;
    auto t1141 = clamp(t1140, 0.0h, 1.0h);
    auto t1142 = fma(t1141, -2.0h, 3.0h);
    half t1143 = t1141 * t1141;
    half t1144 = 0.0 - t1142;
    auto t1145 = fma(t1144, t1143, 1.0h);
    auto t1146 = fma(t1093, t1094, 0.000100017h);
    float t1147 = float(t1145);
    float t1148 = t1125 + t1147;
    half t1149 = half(t1148);
    half t1150 = t1149 + 0.5;
    half t1151 = 0.5 / t1150;
    auto t1152 = log2(t1146);
    half t1153 = t1151 * t1152;
    auto t1154 = exp2(t1153);
    auto t1155 = dot(phi_15, half3(0.0396729, 0.458008, 0.00609589));
    auto t1156 = fma(t1155, 10.0h, 1.0h);
    auto t1157 = t1136.y;
    float t1158 = float(t1157);
    float t1159 = t1125 * t1158;
    half t1160 = half(t1159);
    auto t1161 = t782.x;
    auto t1162 = fma(t1154, t1161, t1160);
    auto t1163 = t1136.z;
    auto t1164 = fma(t1145, t1163, t1162);
    half3 t1165 = 0;
    t1165.x = t1164;
    half3 t1166 = half3(t1165.x);
    half3 t1167 = FGlobals._ElementViewSceneLightColor;
    half3 t1168 = 0;
    t1168.x = t1156;
    half3 t1169 = half3(t1168.x);
    half3 t1170 = t1167 * t1169;
    half3 t1171 = t1170 * t1166;
    half3 t1172 = t762 ? t1171 : 0;
    half3 t1173 = t1172 + phi_15;
    half4 t1174 = half4(t1173[0], t1173[1], t1173[2], 0);
    half4 t1175 = half4(t1174[0], t83[1], t1174[1], t1174[2]);
    phi_18 = t1175; // phi from BB1193
    // BB1306:
    auto t1176 = dot(t727, float3(0.2125, 0.7154, 0.0721));
    float2 t1177 = 0;
    t1177.x = t1176;
    float3 t1178 = float3(t1177.x);
    float3 t1179 = t1178 * t356;
    half2 t1180 = 0;
    t1180.x = t338;
    half2 t1181 = half2(t1180.x);
    bool2 t1182 = t1181 == half2(1.0, 4);
    uchar2 t1183 = uchar2(t1182);
    auto t1184 = t1183.y;
    bool t1185 = t1184 == 0;
    if (t1185) {
        // → BB1325
    } else {
        // → BB1317
    }
    // BB1317:
    float t1186 = 1.0 / t752;
    float t1187 = t1186 * t750;
    auto t1188 = fmax(t1187, 0.025);
    float3 t1189 = 0;
    t1189.x = t1188;
    float3 t1190 = float3(t1189.x);
    float3 t1191 = t1190 * t356;
    auto t1192 = half3(t1191);
    phi_16 = t1192; // phi from BB1317
    // BB1325:
    auto t1193 = half3(t727);
    phi_16 = t1193; // phi from BB1325
    // BB1327:
    auto t1194 = t1183.x;
    bool t1195 = t1194 == 0;
    if (t1195) {
        phi_17 = phi_16; // phi from BB1327
    } else {
        // → BB1331
    }
    // BB1331:
    auto t1196 = half3(t1179);
    phi_17 = t1196; // phi from BB1331
    // BB1333:
    half4 t1197 = half4(phi_17[0], phi_17[1], phi_17[2], 0);
    half4 t1198 = half4(t1197[0], t83[1], t1197[1], t1197[2]);
    phi_18 = t1198; // phi from BB1333
    // BB1337:
    auto t1199 = t751.z;
    float t1200 = 1.0 - t1199;
    float t1201 = 0.0 - t752;
    auto t1202 = fma(t1201, t1200, t750);
    float t1203 = t1199 * t752;
    float t1204 = t1202 / t1203;
    auto t1205 = clamp(t1204, 0.0, 1.0);
    half4 t1206 = FGlobals._ElementViewParamsHalf3;
    auto t1207 = t1206.x;
    float t1208 = float(t1207);
    float t1209 = 0.0 - t1208;
    auto t1210 = fma(t1205, t1209, t1208);
    auto t1211 = phi_18.xzw;
    auto t1212 = float3(t1211);
    float3 t1213 = t1212 - t727;
    auto t1214 = half3(t1213);
    float3 t1215 = 0;
    t1215.x = t1210;
    float3 t1216 = float3(t1215.x);
    auto t1217 = float3(t1214);
    auto t1218 = fma(t1216, t1217, t727);
    auto t1219 = half3(t1218);
    half4 t1220 = half4(t1219[0], t1219[1], t1219[2], 0);
    half4 t1221 = half4(t1220[0], t1220[1], t1220[2], phi_18[3]);
    phi_19 = t1221; // phi from BB1337
    // BB1363:
    auto t1222 = half3(t727);
    half4 t1223 = half4(t1222[0], t1222[1], t1222[2], 0);
    half4 t1224 = half4(t1223[0], t1223[1], t1223[2], t83[3]);
    phi_19 = t1224; // phi from BB1363
    // BB1367:
    auto t1225 = half3(t727);
    half4 t1226 = half4(t1225[0], t1225[1], t1225[2], 0);
    half4 t1227 = half4(t1226[0], t1226[1], t1226[2], t83[3]);
    phi_19 = t1227; // phi from BB1367
    // BB1371:
    half t1228 = half(t682);
    half4 t1229 = phi_19;
    t1229.w = t1228;
    return XlatMtlMain_Out{ t1229, t1229 };
}
