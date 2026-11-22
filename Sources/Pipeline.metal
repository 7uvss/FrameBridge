#include <metal_stdlib>
using namespace metal;
constexpr sampler pixelSampler(coord::pixel, address::clamp_to_edge, filter::linear);
// Native-pixel radius and maximum 8-bit luma delta for stationary detail.
constant int stationaryRadius=3;
constant int stationaryLimit=3;
constexpr sampler screenSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// Average a 4×4 luma footprint using four bilinear fetches.
kernel void reduceLuma(texture2d<float,access::sample> src [[texture(0)]],
                       texture2d<float,access::write> dst [[texture(1)]],
                       uint2 pos [[thread_position_in_grid]]) {
    float2 base = float2(pos * 4) + 1.0;
    float value = src.sample(pixelSampler,base).r + src.sample(pixelSampler,base+float2(2,0)).r
                + src.sample(pixelSampler,base+float2(0,2)).r + src.sample(pixelSampler,base+2.0).r;
    dst.write(float4(value*0.25),pos);
}

float cost(texture2d<float> a, texture2d<float> b, float2 center, float2 delta, float spacing) {
    float residual = 0;
    for(int y=-2; y<=2; ++y) for(int x=-2; x<=2; ++x) {
        float2 p=center+float2(x,y)*spacing;
        residual += abs(a.sample(pixelSampler,p-delta*0.5).r-b.sample(pixelSampler,p+delta*0.5).r);
    }
    return residual/25.0 + min(length(delta)*0.00004,0.0025);
}

// At 1/16 scale a quick turn can be searched over hundreds of source
// pixels without making the fine-resolution search prohibitively expensive.
constexpr sampler pointSampler(coord::pixel,address::clamp_to_edge,filter::nearest);
kernel void largeDisplacement(texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                              texture2d<float,access::write> seed [[texture(2)]],uint2 tile [[thread_position_in_grid]]) {
    float2 center=float2(tile*8)+4.0;
    float2 vec=0;
    float best=cost(a,b,center,vec,1.6);
    if(best>0.001) {
        for(int y=-12;y<=12;y++) for(int x=-24;x<=24;x++) {
            float2 candidate=float2(x,y);
            float score=cost(a,b,center,candidate,1.6);
            if(score<best){best=score;vec=candidate;}
        }
    }
    seed.write(float4(vec*16.0,0,1),tile);
}

// A wider support region distinguishes a fast pan from local motion on
// thin geometry. Keep an independent prediction per 64-pixel region.
kernel void wideMotion(texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                       texture2d<float> seed [[texture(2)]], texture2d<float,access::write> wide [[texture(3)]], uint2 pos [[thread_position_in_grid]]) {
    float2 center=float2(pos*16)+8.0, vec=0;
    float best=cost(a,b,center,vec,2.8);
    if(best>0.001) {
        for(int y=-16;y<=16;y+=2) for(int x=-16;x<=16;x+=2) {
            float2 candidate=float2(x,y);
            float score=cost(a,b,center,candidate,2.8);
            if(score<best){best=score;vec=candidate;}
        }
        // Test surrounding large-region estimates with this tile's own evidence.
        float2 seedGrid=(float2(pos)+0.5)/2.0;
        float2 base=floor(seedGrid-0.5)+0.5;
        for(int i=0;i<4;i++) {
            float2 guess=seed.sample(pointSampler,base+float2(i&1,i>>1)).rg*0.25;
            float score=cost(a,b,center,guess,2.8);
            if(score<best){best=score;vec=guess;}
        }
        for(int step=2;step>=1;step/=2) {
            float2 origin=vec;
            for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
                float2 candidate=origin+float2(x,y)*step;
                float score=cost(a,b,center,candidate,2.8);
                if(score<best){best=score;vec=candidate;}
            }
        }

    }
    wide.write(float4(vec*4,0,1),pos);
}

constexpr sampler nearestPixel(coord::pixel,address::clamp_to_edge,filter::nearest);

// Repeating textures can explain several displacements equally well within
// one tile. Retain a second, neighborhood-supported camera-motion hypothesis.
kernel void dominantMotion(texture2d<float> wide [[texture(0)]],
                           texture2d<float,access::write> dominant [[texture(1)]],
                           uint2 pos [[thread_position_in_grid]]) {
    float2 samples[25];
    for(int y=0;y<5;y++) for(int x=0;x<5;x++)
        samples[5*y+x]=wide.sample(nearestPixel,float2(pos)+float2(x-2,y-2)+0.5).rg;
    float support=-1; float2 selected=samples[12];
    for(int k=0;k<25;k++) {
        float n=0;float2 sum=0;
        for(int j=0;j<25;j++) {
            float2 delta=samples[k]-samples[j];
            float w=saturate(1.0-dot(delta,delta)/49.0);
            n+=w;sum+=w*samples[j];
        }
        if(n>support){support=n;selected=sum/max(n,1.0);}
    }
    dominant.write(float4(selected,0,1),pos);
}

kernel void estimate(texture2d<float> smallA [[texture(0)]], texture2d<float> smallB [[texture(1)]],
                     texture2d<float> a [[texture(2)]], texture2d<float> b [[texture(3)]],
                     texture2d<float> wide [[texture(4)]], texture2d<float> history [[texture(5)]],
                     texture2d<float> dominant [[texture(6)]], texture2d<float,access::write> field [[texture(7)]], constant float &timeRatio [[buffer(0)]],
                     uint2 pos [[thread_position_in_grid]]) {
    float2 center=float2(pos*16)+8.0;
    float2 pan=wide.sample(nearestPixel,center/64.0).rg*0.25, vec=0;
    float best=cost(smallA,smallB,center/4,vec,1);
    float panScore=cost(smallA,smallB,center/4,pan,1);
    if(panScore<best+0.0008){vec=pan;best=panScore;}
    float2 common=dominant.sample(nearestPixel,center/64.0).rg*0.25;
    float commonScore=cost(smallA,smallB,center/4,common,1);
    if(commonScore<best+0.002){vec=common;best=commonScore;}
    if(best>0.001) {
        for(int step=4;step>=1;step/=2) {
            float2 origin=vec;
            for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
                float2 candidate=origin+float2(x,y)*step;
                float score=cost(smallA,smallB,center/4,candidate,1);
                if(score<best){best=score;vec=candidate;}
            }
        }
    }
    vec*=4;
    best=cost(a,b,center,vec,3);
    for(int step=2;step>=1;step/=2) {
        float2 origin=vec;
        for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
            float2 candidate=origin+float2(x,y)*step;
            float score=cost(a,b,center,candidate,3);
            if(score<best){best=score;vec=candidate;}
        }
    }
    // Keep a reprojected velocity when the new pair explains it equally well.
    // The caller invalidates history across cuts, dropped pairs and size changes.
    if(timeRatio>0) {
        float2 oldCenter=center-vec*0.5*(1+1/timeRatio);
        float2 prior=history.sample(nearestPixel,oldCenter/16).rg*timeRatio;
        float priorScore=cost(a,b,center,prior,3);
        if(priorScore<best+0.0015){best=priorScore;vec=prior;}
    }
    // Fractional motion is visible on narrow high-contrast silhouettes.
    for(float step=0.5;step>=0.25;step*=0.5) {
        float2 origin=vec;
        for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
            float2 candidate=origin+float2(x,y)*step;
            float score=cost(a,b,center,candidate,3);
            if(score+0.00008<best){best=score;vec=candidate;}
        }
    }
    field.write(float4(vec,0,1),pos);
}

// Compare the same small luma patch in both endpoints for each motion
// hypothesis. Chroma helps distinguish similarly bright foreground/background.
float patchError(texture2d<float> a,texture2d<float> b,texture2d<float> ca,texture2d<float> cb,
                 float2 p,float2 flow,float phase) {
    float2 u=p-flow*phase, v=p+flow*(1.0-phase);
    float sum=0;
    float minA=1, minB=1, maxA=0, maxB=0;
    const float2 offsets[]={float2(0),float2(-3,0),float2(3,0),float2(0,-3),float2(0,3)};
    for(int i=0;i<5;i++) {
        float x=a.sample(pixelSampler,u+offsets[i]).r,y=b.sample(pixelSampler,v+offsets[i]).r;
        sum+=abs(x-y);
        minA=min(minA,x);maxA=max(maxA,x);minB=min(minB,y);maxB=max(maxB,y);
    }
    float2 chroma=abs(ca.sample(pixelSampler,u*0.5).rg-cb.sample(pixelSampler,v*0.5).rg);
    float mismatch=sum*0.2+0.16*(chroma.x+chroma.y);
    return mismatch-0.22*min(0.25,min(maxA-minA,maxB-minB))*(1.0-smoothstep(0.008,0.035,mismatch));
}

static float4 resolveAt(texture2d<float> a,texture2d<float> b,texture2d<float> ca,texture2d<float> cb,
                        texture2d<float> field,texture2d<float> wide,texture2d<float> dominant,float phase,uint2 pos) {
    float2 p=float2(pos)+0.5;
    float2 tile=p/16.0, base=floor(tile-0.5)+0.5;
    float2 local=field.sample(nearestPixel,tile).rg;
    float2 pan=wide.sample(nearestPixel,p/64.0).rg;
    float2 common=dominant.sample(nearestPixel,p/64.0).rg;
    // Smooth subpixel variation inside a moving surface. Clamp interpolation
    // to the local hypothesis so unrelated foreground/background vectors cannot mix.
    float2 smooth=field.sample(pixelSampler,tile).rg;
    float2 bestFlow=distance(smooth,local)<1.25 ? smooth : local;
    float best=patchError(a,b,ca,cb,p,bestFlow,phase);
    float2 initial=bestFlow;
    if(any(common!=initial)) {
        float score=patchError(a,b,ca,cb,p,common,phase);
        if(score+0.0005<best){bestFlow=common;best=score;}
    }
    for(int i=0;i<6;i++) {
        float2 off=float2(i&1,(i>>1)&1);
        float2 candidate=i<4 ? field.sample(nearestPixel,base+off).rg : (i==4 ? pan : float2(0));
        if(all(candidate==bestFlow) || all(candidate==initial) || all(candidate==common)) continue;
        float score=patchError(a,b,ca,cb,p,candidate,phase);
        // Retain the spatially closest block in ambiguous flat regions.
        if(score+0.001<best){best=score;bestFlow=candidate;}
    }
    // Limit abrupt source switching on ambiguous foliage and occlusion boundaries.
    float nearWeight=phase<=0.5 ? phase*0.4 : 1.0-(1.0-phase)*0.4;
    float weight=mix(phase,nearWeight,smoothstep(0.035,0.13,best));
    // Trust moving detail when the warped patch matches in both endpoints
    // and follows the surrounding camera motion. Taper confidence near borders.
    float agreement=max(1.0-smoothstep(0.5,3.0,distance(bestFlow,common)),smoothstep(0.001,0.020,-best));
    float residual=1.0-smoothstep(0.004,0.035,best);
    float2 margin=min(p,float2(a.get_width(),a.get_height())-p)-abs(bestFlow)*max(phase,1.0-phase);
    float reliable=agreement*residual*smoothstep(2.0,8.0,length(bestFlow))
                  *smoothstep(1.0,5.0,min(margin.x,margin.y));
    return float4(bestFlow,weight,reliable);
}

kernel void resolveMotion(texture2d<float> a [[texture(0)]],texture2d<float> b [[texture(1)]],
                          texture2d<float> ca [[texture(2)]],texture2d<float> cb [[texture(3)]],
                          texture2d<float> field [[texture(4)]],texture2d<float> wide [[texture(5)]],
                          texture2d<float> dominant [[texture(6)]], texture2d<float,access::write> guidance [[texture(7)]],
                          constant float &phase [[buffer(1)]],uint2 pos [[thread_position_in_grid]]) {
    guidance.write(resolveAt(a,b,ca,cb,field,wide,dominant,phase,pos),pos);
}

kernel void resolveDonor(texture2d<float> a [[texture(0)]],texture2d<float> b [[texture(1)]],
                          texture2d<float> ca [[texture(2)]],texture2d<float> cb [[texture(3)]],
                          texture2d<float> field [[texture(4)]],texture2d<float> wide [[texture(5)]],
                          texture2d<float> dominant [[texture(6)]], texture2d<float,access::write> guidance [[texture(7)]],
                          texture2d<float,access::write> luma [[texture(8)]], constant float &phase [[buffer(1)]],uint2 pos [[thread_position_in_grid]]) {
    // Match the half-precision intermediate used by the two-pass path.
    float4 flow=float4(half4(resolveAt(a,b,ca,cb,field,wide,dominant,phase,pos)));
    float2 p=float2(pos)+0.5;
    float left=a.sample(pixelSampler,p-flow.rg*phase).r;
    float right=b.sample(pixelSampler,p+flow.rg*(1-phase)).r;
    luma.write(float4(mix(left,right,flow.b)),pos);
    guidance.write(float4(flow.w),pos);
}

kernel void synthesize(texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                       texture2d<float> guidance [[texture(2)]], texture2d<float,access::write> dst [[texture(3)]],
                       constant float &planeScale [[buffer(0)]], constant float &phase [[buffer(1)]], uint2 pos [[thread_position_in_grid]]) {
    float2 p=float2(pos)+0.5;
    float4 motion=guidance.sample(nearestPixel,p*planeScale);
    float2 flow=motion.rg/planeScale;
    float4 previous=a.sample(pixelSampler,p-flow*phase), next=b.sample(pixelSampler,p+flow*(1.0-phase));
    dst.write(mix(previous,next,motion.b),pos);
}

// Test candidate translations against a sparse grid spanning the frame.
// A clipped residual limits the influence of independently moving objects.
kernel void scoreCameraParallel(texture2d<float> left [[texture(0)]], texture2d<float> right [[texture(1)]],
                        texture2d<float> wide [[texture(2)]], texture2d<float> fine [[texture(3)]],
                        texture2d<float,access::write> scores [[texture(4)]], uint2 pos [[threadgroup_position_in_grid]],
                        uint lane [[thread_index_in_simdgroup]], uint lanes [[threads_per_simdgroup]]) {
    float2 shift=((pos.x+pos.y)&1u) ? fine.sample(nearestPixel,float2(pos*4+2)+0.5).rg : wide.read(pos).rg;
    if(all(pos==uint2(0))) shift=0;
    float2 size=float2(left.get_width(),left.get_height());
    float error=0;
    for(uint i=lane;i<192;i+=lanes) {
        float2 cell=float2(i%16,i/16);
        float2 jitter=float2((i*17u)%29u,(i*11u)%31u)/32.0;
        float2 p=floor((cell+jitter+0.1)/float2(16,12)*(size-128.0))+64.5;
        float a=left.sample(pixelSampler,p).r;
        float b=right.sample(pixelSampler,p+shift).r;
        error+=min(abs(a-b),0.095);
    }
    error=simd_sum(error);
    if(lane==0) scores.write(float4(shift,error/192.0,0),pos);
}
kernel void estimateCamera(texture2d<float> scores [[texture(0)]],texture2d<float,access::write> output [[texture(1)]],
                           uint2 pos [[thread_position_in_grid]]) {
    float4 best=scores.read(uint2(0));
    float stationary=best.z;
    for(uint y=0;y<scores.get_height();y++) for(uint x=0;x<scores.get_width();x++) {
        float4 hypothesis=scores.read(uint2(x,y));
        if(hypothesis.z<best.z) best=hypothesis;
    }
    float gain=(stationary-best.z)/max(stationary,0.0001);
    float confidence=smoothstep(0.2,0.7,gain)*smoothstep(2.0,6.0,length(best.xy));
    output.write(float4(best.xy,confidence,0),pos);
}

// Score translations in a horizontal strip. During a sideways camera move
// surfaces at different depths often have different projected velocities.
float bandError(texture2d<float> left,texture2d<float> right,uint band,float2 displacement,uint lane,uint lanes) {
    float2 size=float2(left.get_width(),left.get_height());
    float error=0;
    for(uint i=lane;i<256;i+=lanes) {
        float2 p=floor(float2(48+(i%32+(i*11%29)/30.0)*(size.x-96)/32.0,
                              min(size.y-4,(band+(i/32+(i*7%17)/18.0)/8.0)*64.0)))+0.5;
        float a=left.sample(pixelSampler,p).r,b=right.sample(pixelSampler,p+displacement).r;
        error+=min(abs(a-b),0.12);
    }
    return simd_sum(error);
}
kernel void scoreBandsParallel(texture2d<float> left [[texture(0)]], texture2d<float> right [[texture(1)]],
                       texture2d<float> wide [[texture(2)]],texture2d<float> fine [[texture(3)]],
                       texture2d<float> camera [[texture(4)]],texture2d<float,access::write> scores [[texture(5)]],
                       uint2 cell [[threadgroup_position_in_grid]],
                       uint lane [[thread_index_in_simdgroup]], uint lanes [[threads_per_simdgroup]]) {
    float2 size=float2(left.get_width(),left.get_height());
    float2 q=float2((float(cell.x%32)+0.5)*size.x/32.0,(cell.y+0.5)*64.0);
    float2 displacement=fine.sample(nearestPixel,(q+float2(0,(int(cell.x/32)-1)*15))/16.0).rg;
    if(cell.x<32) displacement=wide.sample(nearestPixel,q/64.0).rg;
    if(cell.x==0) displacement=0;
    if(cell.x==1) displacement=camera.read(uint2(0)).xy;
    float error=bandError(left,right,cell.y,displacement,lane,lanes);
    if(lane==0) scores.write(float4(displacement,error,0),cell);
}
// Refine in capture-pixel units. Thin geometry often exposes a vertical
// registration error of only one pixel that coarse block flow cannot resolve.
kernel void refineBandsParallel(texture2d<float> left [[texture(0)]],texture2d<float> right [[texture(1)]],
                        texture2d<float> seeds [[texture(2)]],texture2d<float,access::write> scores [[texture(3)]],
                        uint2 cell [[threadgroup_position_in_grid]],
                       uint lane [[thread_index_in_simdgroup]], uint lanes [[threads_per_simdgroup]]) {
    float2 seed=round(seeds.read(uint2(0,cell.y)).xy);
    float2 flow=cell.x==0 ? float2(0) : seed+float2(int(cell.x%16)-8,int(cell.x/16)-4);
    float error=bandError(left,right,cell.y,flow,lane,lanes);
    if(lane==0) scores.write(float4(flow,error,0),cell);
}
kernel void selectBand(texture2d<float> scores [[texture(0)]],texture2d<float,access::write> bands [[texture(1)]],
                       uint2 pos [[thread_position_in_grid]]) {
    float4 best=scores.read(uint2(0,pos.y));
    float stationary=best.z;
    for(uint x=1;x<scores.get_width();x++) {
        float4 candidate=scores.read(uint2(x,pos.y));
        if(candidate.z<best.z) best=candidate;
    }
    float gain=(stationary-best.z)/max(stationary,0.001);
    bands.write(float4(best.xy,smoothstep(0.12,0.6,gain),0),pos);
}

// Transfer the fine band of the motion-compensated 1080p prediction only
// where its surrounding structure agrees with the model's midpoint.
kernel void restoreDetail(texture2d<float> guide [[texture(0)]], texture2d<float> prediction [[texture(1)]],
                          texture2d<float> left [[texture(2)]], texture2d<float> right [[texture(3)]],
                          texture2d<float> camera [[texture(4)]],
                          texture2d<float> localMotion [[texture(5)]],
                          texture2d<float> bands [[texture(6)]],texture2d<float,access::write> dst [[texture(7)]], uint2 pos [[thread_position_in_grid]]) {
    float2 p=float2(pos)+0.5;
    float g=guide.read(pos).r, d=prediction.read(pos).r;
    float gm=0,dm=0, mismatch=0,lo=min(g,d),hi=max(g,d);
    const float2 offsets[]={float2(-1.5,-1.5),float2(1.5,-1.5),float2(-1.5,1.5),float2(1.5,1.5)};
    // Stationary HUD and fine textures survive interpolation at native luma.
    // Check a neighborhood to avoid treating crossing edges as a stationary point.
    float a=left.read(pos).r, b=right.read(pos).r;
    if(abs(a-b)<(stationaryLimit+0.5)/255.0 && min(abs(a-g),abs(a-d))<0.08) {
        float drift=abs(a-b);
        for(int i=0;i<4;i++) {
            float2 q=p+offsets[i]*(stationaryRadius/1.5);
            drift=max(drift,abs(left.sample(pixelSampler,q).r-right.sample(pixelSampler,q).r));
        }
        if(drift<(stationaryLimit+0.5)/255.0) {
            dst.write(float4(0.5*(a+b)),pos);
            return;
        }
    }
    // Verify the global hypothesis on both sides of this pixel before using it.
    float4 pan=camera.read(uint2(0));
    float panLuma=0, trust=0;
    float4 band=bands.sample(pixelSampler,float2(0.5,p.y/64.0));
    float4 nearest=bands.sample(nearestPixel,float2(0.5,p.y/64.0));
    if(distance(band.xy,nearest.xy)>4.0) band=nearest;
    if(pan.z>0) {
        float2 u=p-0.5*pan.xy, v=p+0.5*pan.xy;
        float2 margin=min(p,float2(left.get_width(),left.get_height())-p)-0.5*abs(pan.xy);
        float la=left.sample(pixelSampler,u).r, rb=right.sample(pixelSampler,v).r;
        float error=abs(la-rb);
        for(int i=0;i<4;i++) {
            float2 q=offsets[i]*2.0;
            error=max(error,abs(left.sample(pixelSampler,u+q).r-right.sample(pixelSampler,v+q).r));
        }
        panLuma=0.5*(la+rb);
        trust=pan.z*(1.0-smoothstep(0.004,0.045,error))*smoothstep(1.0,5.0,min(margin.x,margin.y));
        if(trust>=0.9999 && (band.z<0.1 || distance(band.xy,pan.xy)<1.0)) { dst.write(float4(panLuma),pos); return; }
    }
    float bandTrust=0, bandLuma=0;
    if(band.z>0.01 && length(band.xy)>2) {
        float2 u=p-band.xy*0.5,v=p+band.xy*0.5;
        float la=left.sample(pixelSampler,u).r, rb=right.sample(pixelSampler,v).r;
        float error=abs(la-rb);
        float leftMean=0, rightMean=0, guideMean=0, leftGap=0, rightGap=0;
        for(int i=0;i<4;i++) {
            float2 q=offsets[i]*2.0;
            float l=left.sample(pixelSampler,u+q).r, r=right.sample(pixelSampler,v+q).r;
            float m=guide.sample(pixelSampler,p+q).r;
            error=max(error,abs(l-r));
            leftMean+=l; rightMean+=r; guideMean+=m;
            leftGap+=min(abs(l-m),0.25); rightGap+=min(abs(r-m),0.25);
        }
        float2 margin=min(p,float2(left.get_width(),left.get_height())-p)-0.5*abs(band.xy);
        float spatial=band.z*smoothstep(1.0,5.0,min(margin.x,margin.y));
        bandTrust=spatial*(1.0-smoothstep(0.005,0.052,error));
        bandLuma=0.5*(la+rb);
        // In a disocclusion only one warped endpoint shows the background.
        // Use a low-frequency patch comparison to decide which side is visible.
        leftGap=0.25*(leftGap+abs(leftMean-guideMean));
        rightGap=0.25*(rightGap+abs(rightMean-guideMean));
        float separation=smoothstep(0.012,0.085,abs(leftGap-rightGap));
        float support=1.0-smoothstep(0.03,0.14,min(leftGap,rightGap));
        float oneSide=spatial*separation*support*smoothstep(0.025,0.10,error);
        if(oneSide>bandTrust) {
            bandLuma=leftGap<rightGap ? la : rb;
            bandTrust=oneSide;
        }
    }
    for(int i=0;i<4;i++) {
        float v=guide.sample(pixelSampler,p+offsets[i]).r;
        float q=prediction.sample(pixelSampler,p+offsets[i]).r;
        gm+=v;dm+=q;mismatch+=abs(v-q);
        lo=min(lo,q);hi=max(hi,q);
    }
    gm*=0.25;dm*=0.25;
    float confidence=1-smoothstep(0.020,0.090,0.5*abs(dm-gm)+0.125*mismatch);
    float correction=(d-dm)-(g-gm);
    float result=g+confidence*clamp(correction,-0.23,0.23);
    // At depth discontinuities a locally consistent motion can differ from the
    // camera translation. Only borrow its detail where both source patches agree.
    float localTrust=0.65*localMotion.read(pos).r;
    float localLuma=mix(clamp(result,lo,hi),d,localTrust);
    dst.write(float4(mix(mix(localLuma,panLuma,trust),bandLuma,bandTrust)),pos);
}

struct Vertex {float4 position [[position]]; float2 uv;};
vertex Vertex screenVertex(uint i [[vertex_id]]) {
    const float2 coords[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
    float2 p=coords[i];
    return {float4(p,0,1),float2((p.x+1)*0.5,(1-p.y)*0.5)};
}
fragment float4 screenFragment(Vertex v [[stage_in]], texture2d<float> luma [[texture(0)]],
                               texture2d<float> chroma [[texture(1)]], constant float2 &krkb [[buffer(0)]]) {
    float y=(luma.sample(screenSampler,v.uv).r*255-16)/219;
    float2 uv=(chroma.sample(screenSampler,v.uv).rg*255-128)/224;
    float r=y+2*(1-krkb.x)*uv.y, b=y+2*(1-krkb.y)*uv.x;
    return float4(r,(y-krkb.x*r-krkb.y*b)/(1-krkb.x-krkb.y),b,1);
}
